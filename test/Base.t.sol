// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {
    CompactEnvironment,
    ModuleKitHelpers,
    TestHelperLib,
    Element,
    Mandate
} from "@rhinestone/compact-utils/src/tests/Environment.sol";
import { AccountInstance } from "modulekit/ModuleKit.sol";
import { MockENS } from "src/mocks/MockENS.sol";
import { ENSValidator } from "src/validator/ENSValidator.sol";
import { MODULE_TYPE_VALIDATOR } from "modulekit/accounts/common/interfaces/IERC7579Module.sol";
import { IPermit2IntentExecutor } from "@rhinestone/compact-utils/src/executor/interfaces/IPermit2Intent.sol";
import { Types } from "@rhinestone/compact-utils/src/types/OrderTypes.sol";
import { SmartExecutionLib } from "@rhinestone/compact-utils/src/common/SmartExecutionLib.sol";
import { IntentExecutorAdapter } from "@rhinestone/compact-utils/src/adapters/IntentExecutorAdapter.sol";
import { EIP712TypeHashLib } from "@rhinestone/compact-utils/src/types/EIP712TypeHashLib.sol";
import { IEmissary, IStatelessValidator } from "@rhinestone/compact-utils/src/emissary/Emissary.sol";

contract BaseTest is CompactEnvironment {
    using ModuleKitHelpers for *;

    MockENS ens;
    ENSValidator multisig;
    IntentExecutorAdapter adapter;

    Account browserECDSA;
    AccountInstance hca;

    uint256 internal immutable namechain = 56_565_656;

    function setUp() public virtual {
        _deployCompact();
        _deploySmartAccount({ create: true });
        _setEmissary(env.smartAccount1, env.eoa);
        _lockAssets(env.smartAccount1, env.token1, 100 ether);

        hca = env.smartAccount1;

        browserECDSA = makeAccount("browserECDSA");

        // Instantiate MockENS with token1 as the payment token
        ens = new MockENS(address(env.token1));

        // Instantiate ENSValidator (multisig)
        multisig = new ENSValidator();

        // Install the ENS validator multisig on smartAccount1
        ENSValidator.Owner[] memory ownersWithExpiration = new ENSValidator.Owner[](1);
        ownersWithExpiration[0] = ENSValidator.Owner({ addr: browserECDSA.addr, expiration: 0 }); // 0 = no expiration

        bytes memory initData = abi.encode(1, ownersWithExpiration); // threshold of 1
        env.smartAccount1.installModule({
            moduleTypeId: MODULE_TYPE_VALIDATOR,
            module: address(multisig),
            data: initData
        });

        // Set up emissary for hca with browserECDSA as the signer
        // This enables cross-chain intents with the browserECDSA key
        _setEmissaryWithCustomValidator(hca, browserECDSA, address(multisig));

        // Deploy the IntentExecutorAdapter
        adapter = new IntentExecutorAdapter(address(env.router), address(env.intentExecutor));

        // Install the adapter for both function selectors on the router
        _setFillRoute(adapter.handleFill_intentExecutor_handleCompactTargetOps.selector, address(adapter));
        _setFillRoute(adapter.handleFill_intentExecutor_handlePermit2TargetOps.selector, address(adapter));
    }

    function _getEIP712Stubs_Permit2TargetOps(
        Element memory element,
        uint256 nonce,
        uint256 expires
    )
        internal
        returns (
            IPermit2IntentExecutor.EIP712Permit2MandateDestinationStub memory mandateStub,
            IPermit2IntentExecutor.EIP712Permit2Stub memory permit2Stub
        )
    {
        // Create permit2 stub with basic parameters
        permit2Stub = IPermit2IntentExecutor.EIP712Permit2Stub({ nonce: nonce, expires: expires });

        // Hash operations properly for the mandate
        Types.Operation memory preClaimOpsOperation = SmartExecutionLib.encode(
            SmartExecutionLib.SigMode.ERC1271, element.mandate.originOps
        );
        Types.Operation memory destOpsOperation = SmartExecutionLib.encode(
            SmartExecutionLib.SigMode.ERC1271, element.mandate.destOps
        );

        bytes32 preClaimOpsHash = this.jump_hashEIP712(preClaimOpsOperation);
        bytes32 destOpsHash = this.jump_hashEIP712(destOpsOperation);

        // Create mandate stub with proper hashes that match executor expectations
        mandateStub = IPermit2IntentExecutor.EIP712Permit2MandateDestinationStub({
            sponsor: element.mandate.target.recipient,
            arbiter: element.arbiter,
            notarizedChainId: element.chainId,
            preClaimOpsHash: preClaimOpsHash,
            targetAttributesHash: keccak256(
                abi.encode(
                    element.mandate.target.recipient,
                    element.mandate.target.tokenOut,
                    element.mandate.target.targetChain,
                    element.mandate.target.fillExpiry
                )
            ),
            tokenInHash: keccak256(abi.encode(element.idsAndAmounts)),
            tokenOutHash: keccak256(abi.encode(element.mandate.target.tokenOut)),
            fillExpires: element.mandate.target.fillExpiry,
            qHash: keccak256(abi.encode(element.mandate.q))
        });
    }

    function _createPermit2Hash(
        IPermit2IntentExecutor.EIP712Permit2Stub memory permit2Stub,
        IPermit2IntentExecutor.EIP712Permit2MandateDestinationStub memory mandateStub,
        Types.Operation memory targetOps
    )
        internal
        returns (bytes32 permit2Hash)
    {
        // Replicate the executor's hash computation exactly
        bytes32 mandateHash = EIP712TypeHashLib.hashMandateRaw({
            targetAttributes: mandateStub.targetAttributesHash,
            v: uint8(SmartExecutionLib.SigMode.ERC1271),
            minGas: 0,
            preClaimOpsHash: mandateStub.preClaimOpsHash,
            destOpsHash: this.jump_hashEIP712(targetOps),
            qHash: mandateStub.qHash
        });

        // Create the final permit2 hash exactly as the executor does
        permit2Hash = EIP712TypeHashLib.hashPermit2({
            tokenInHash: mandateStub.tokenInHash,
            arbiter: mandateStub.arbiter,
            nonce: permit2Stub.nonce,
            expires: permit2Stub.expires,
            mandate: mandateHash
        });
    }

    function _setEmissaryWithCustomValidator(
        AccountInstance storage instance,
        Account storage signer,
        address validatorAddr
    )
        internal
        virtual
    {
        address account = instance.account;

        uint256[] memory chainIds = new uint256[](3);
        chainIds[0] = chains.originChain1;
        chainIds[1] = chains.originChain2;
        chainIds[2] = namechain;

        address[] memory signers = new address[](1);
        signers[0] = signer.addr;

        IEmissary.EmissaryConfig memory config = IEmissary.EmissaryConfig({
            configId: env.emissaryId,
            allocator: address(env.allocator),
            scope: env.scope,
            resetPeriod: env.resetPeriod,
            validator: IStatelessValidator(validatorAddr),
            validatorConfig: abi.encode(uint256(1), signers)
        });

        IEmissary.EmissaryEnable memory enableData;
        enableData.chainIndex = 0;
        enableData.allChainIds = chainIds;
        enableData.expires = block.timestamp + 1;
        enableData.nonce = 1;

        env.emissary.mock_setConfig(
            account, env.emissaryId, env.lockTag, IStatelessValidator(validatorAddr), config.validatorConfig
        );
    }
}

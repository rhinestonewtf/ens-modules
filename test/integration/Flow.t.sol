// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Base.t.sol";
import { IETHRegistrarController } from "src/interfaces/IENSRegistrarController.sol";
import { Execution } from "modulekit/integrations/ERC7579Exec.sol";
import { MockENS } from "src/mocks/MockENS.sol";
import { Target } from "@rhinestone/compact-utils/src/types/TheCompactStructs.sol";
import {
    IntentExecutorAdapter
} from "@rhinestone/compact-utils/src/adapters/IntentExecutorAdapter.sol";
import {
    IStandaloneIntentExecutor
} from "@rhinestone/compact-utils/src/executor/interfaces/IStandaloneIntent.sol";
import { Types } from "@rhinestone/compact-utils/src/types/OrderTypes.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import "forge-std/console2.sol";
import {
    EIP712Lib
} from "@rhinestone/compact-utils/src/executor/StandaloneIntent/lib/EIP712Lib.sol";

contract FlowTest is BaseTest {
    using TestHelperLib for *;

    function test_ensflow() public {
        // Frontend prepares registration
        IETHRegistrarController.Registration memory registration =
            IETHRegistrarController.Registration({
                label: "foobar",
                owner: env.eoa.addr,
                duration: 730 days, // 2 years
                secret: keccak256("supersecret"),
                resolver: address(0),
                data: new bytes[](0),
                reverseRecord: 0,
                referrer: bytes32(0)
            });
        // calculates commit hash
        bytes32 commitHash = ens.makeCommitment(registration);

        // Funding and commit Intent
        Execution[] memory commit = new Execution[](1);
        commit[0] = Execution({
            target: address(ens), value: 0, callData: abi.encodeCall(MockENS.commit, (commitHash))
        });

        intent.compact.sponsor = env.eoa.addr;
        intent.compact.nonce = 1337;
        intent.compact.expires = block.timestamp + 1 minutes;
        intent.compact.elements
            .push(
                Element({
                    arbiter: makeAddr("arbiter"),
                    chainId: chains.originChain1,
                    idsAndAmounts: [toId(env.token1), 0.01 ether].into(),
                    mandate: Mandate({
                        target: Target({
                            // cross chain intent where sponsor != recipient
                            recipient: hca.account,
                            tokenOut: [toId(env.token1), 0.01 ether].into(),
                            targetChain: namechain,
                            fillExpiry: uint32(block.timestamp + 1 minutes)
                        }),
                        originOps: intent.noExec,
                        // namechain ops: call into commmit()
                        destOps: commit,
                        q: "",
                        minGas: 0,
                        v: SmartExecutionLib.SigMode.ERC1271
                    })
                })
            );

        (
            IPermit2IntentExecutor.EIP712Permit2MandateDestinationStub memory mandateStub,
            IPermit2IntentExecutor.EIP712Permit2Stub memory permit2Stub
        ) = _getEIP712Stubs_Permit2TargetOps(
            intent.compact.elements[0], intent.compact.nonce, intent.compact.expires
        );

        Types.Operation memory targetOps = Types.Operation({
            data: abi.encodePacked(
                SmartExecutionLib.Type.ERC7579,
                SmartExecutionLib.SigMode.ERC1271,
                abi.encode(commit)
            )
        });

        // Create the permit2 hash exactly as the executor will
        bytes32 permit2Hash = _createPermit2Hash(permit2Stub, mandateStub, targetOps);

        // Create proper digest using Environment.sol helper
        // Use the notarized chain (element.chainId) not the fill chain (namechain)!
        bytes32 digest = _hashTypedDataPermit2(chains.originChain1, permit2Hash);

        // Sign the digest directly with raw ECDSA (digest is already the final hash to sign)
        bytes memory ecdsaSig = _signHashRaw(browserECDSA, digest);
        // For ERC7579 ERC1271 mode, prepend the validator address (first 20 bytes)
        bytes memory signature = abi.encodePacked(address(multisig), ecdsaSig);

        bytes memory executorCalldata =
            abi.encode(hca.account, permit2Stub, mandateStub, targetOps, signature);

        // Prepare the adapter call
        bytes[] memory adapterCalldatas = new bytes[](1);
        adapterCalldatas[0] = abi.encodeCall(
            adapter.handleFill_intentExecutor_handlePermit2TargetOps, (executorCalldata)
        );

        // Execute with proper signature
        // simulate a fill transfer
        env.token1.mint(hca.account, 0.01 ether);
        _fill(namechain, new bytes[](0), adapterCalldatas);

        // Verify that the commit was actually executed on the MockENS contract
        uint256 commitmentTimestamp = ens.commitments(commitHash);
        assertGt(commitmentTimestamp, 0, "Commitment should have been recorded");
        assertEq(
            commitmentTimestamp, block.timestamp, "Commitment timestamp should match current block"
        );

        // Registration Intent using standalone multichain ops on namechain
        // Need to wait MIN_COMMITMENT_AGE before registering
        vm.warp(block.timestamp + 1 minutes + 1);

        Execution[] memory registrationExec = new Execution[](2);
        registrationExec[0] = Execution({
            target: address(env.token1),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(ens), type(uint256).max))
        });
        registrationExec[1] = Execution({
            target: address(ens),
            value: 0,
            callData: abi.encodeCall(MockENS.registerWithERC20, (registration))
        });

        // Create MultiChainOps for standalone execution
        IStandaloneIntentExecutor.MultiChainOps memory multichainOps =
            IStandaloneIntentExecutor.MultiChainOps({
                account: hca.account,
                chainIndex: 0,
                otherChains: new bytes32[](0), // No other chains
                nonce: 1,
                ops: registrationExec.toOperation(SmartExecutionLib.SigMode.ERC1271),
                signature: "" // Will be filled after signing
            });

        // Hash the multichain ops (must compute on namechain since that's where it will execute)
        vm.chainId(namechain);
        bytes32 multichainHash = this.hashMultiChainOps(multichainOps);

        // Compute the chain-agnostic digest for signing (same as executor will validate)
        bytes32 regDigest = _hashTypedDataSansChainId(multichainHash);

        // Sign with browserECDSA (raw signature + validator address for ERC1271)
        bytes memory regEcdsaSig = _signHashRaw(browserECDSA, regDigest);
        multichainOps.signature = abi.encodePacked(address(multisig), regEcdsaSig);

        // Prepare adapter calldata for IntentExecutor
        // encode() only encodes the parameters, not the selector
        bytes memory regExecutorCalldata = abi.encode(multichainOps);

        bytes[] memory regAdapterCalldatas = new bytes[](1);
        regAdapterCalldatas[0] = abi.encodeCall(
            adapter.handleFill_intentExecutor_executeMultichainOps, (regExecutorCalldata)
        );

        // Execute on namechain (already on namechain from hashing above)
        _fill(namechain, new bytes[](0), regAdapterCalldatas);

        // Verify registration was successful
        bytes32 labelhash = keccak256(bytes(registration.label));
        address nameOwner = ens.ownerOf(uint256(labelhash));
        assertEq(
            nameOwner, registration.owner, "ENS name should be registered to the correct owner"
        );
    }

    // Helper function to hash MultiChainOps
    function hashMultiChainOps(IStandaloneIntentExecutor.MultiChainOps calldata multichainOps)
        external
        view
        returns (bytes32)
    {
        (bytes32 hash,,,) = EIP712Lib.hashAndDecode(multichainOps);
        return hash;
    }
}

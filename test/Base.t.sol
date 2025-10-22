import "@rhinestone/compact-utils/src/tests/Environment.sol";
import { MockENS } from "src/mocks/MockENS.sol";
import { ENSValidator } from "src/validator/ENSValidator.sol";
import { MODULE_TYPE_VALIDATOR } from "modulekit/accounts/common/interfaces/IERC7579Module.sol";

contract BaseTest is CompactEnvironment {
    using ModuleKitHelpers for *;

    MockENS ens;
    ENSValidator multisig;

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

        // Instantiate OwnableValidator (multisig)
        multisig = new ENSValidator();

        // Install the ownable validator multisig on smartAccount1
        OwnableValidator.Owner[] memory ownersWithExpiration = new OwnableValidator.Owner[](1);
        ownersWithExpiration[0] = OwnableValidator.Owner({ addr: brownerECDSA.addr, expiration: 0 }); //0
            // = no expiration

        bytes memory initData = abi.encode(1, ownersWithExpiration); // threshold of 1
        env.smartAccount1
            .installModule({
                moduleTypeId: MODULE_TYPE_VALIDATOR, module: address(multisig), data: initData
            });
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
            SmartExecutionLib.SigMode.EMISSARY_ERC1271, element.mandate.originOps
        );
        Types.Operation memory destOpsOperation = SmartExecutionLib.encode(
            SmartExecutionLib.SigMode.EMISSARY_ERC1271, element.mandate.destOps
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
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Base.t.sol";
import { IETHRegistrarController } from "src/interfaces/IENSRegistrarController.sol";
import { Execution } from "modulekit/integrations/ERC7579Exec.sol";
import { MockENS } from "src/mocks/MockENS.sol";
import { Target } from "@rhinestone/compact-utils/src/types/TheCompactStructs.sol";

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
        _fill(namechain, new bytes[](0), adapterCalldatas);

        // Verify that the commit was actually executed on the MockENS contract
        uint256 commitmentTimestamp = ens.commitments(commitHash);
        assertGt(commitmentTimestamp, 0, "Commitment should have been recorded");
        assertEq(commitmentTimestamp, block.timestamp, "Commitment timestamp should match current block");

        // Register Intent
        // samechain intent with browserECDSA as signer
        //

        // claim on origin chain

        // create fill that sends funds to HCA

        // fill samechain
    }

    // uint256 notarizedChain = chains.originChain1;
    // address recipient = env.smartAccount1.account;
    // uint256 depositId = 1337;
    //
    // intent.compact.sponsor = env.smartAccount1.account;
    // intent.compact.nonce = 1337;
    // intent.compact.expires = 4141;
    //
    // intent.compact.elements
    // .push(
    // Element({
    // arbiter: address(eco.arbiter),
    // chainId: notarizedChain,
    // idsAndAmounts: [toId(env.token1), 100].into(),
    // mandate: Mandate({
    // target: Target({
    // recipient: recipient,
    // tokenOut: [toId(env.token2), 10].into(),
    // targetChain: chains.targetChain,
    // fillExpiry: uint32(block.timestamp + 1 hours)
    // }),
    // originOps: intent.noExec,
    // destOps: intent.targetExecutions,
    // q: EcoQualifierDataEncodingLib.encode(address(eco.prover)),
    // minGas: 0,
    // v: SmartExecutionLib.SigMode.EMISSARY_ERC1271
    //})
    //})
    //);
    // intent.compact.elements
    // .push(
    // Element({
    // arbiter: address(eco.arbiter),
    // chainId: chains.originChain2,
    // idsAndAmounts: [toId(env.token1), 20].into(),
    // mandate: Mandate({
    // target: Target({
    // recipient: recipient,
    // tokenOut: [toId(env.token2), 10].into(),
    // targetChain: chains.targetChain,
    // fillExpiry: uint32(block.timestamp + 1 hours)
    // }),
    // originOps: intent.noExec,
    // destOps: intent.noExec,
    // q: EcoQualifierDataEncodingLib.encode(address(eco.prover)),
    // minGas: 0,
    // v: SmartExecutionLib.SigMode.EMISSARY_ERC1271
    //})
    //})
    //);
    //
    // _makeClaimHash(address(eco.arbiter));
    // intent.digest = _hashTypedData(notarizedChain, intent.claimHash);
    //
    // // user signs once
    // intent.userEmissarySig =
    // _emissarySig({ smartAccount: env.smartAccount1, with: env.eoa, digest: intent.digest }); }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { MockENS } from "src/mocks/MockENS.sol";
import { IETHRegistrarController } from "src/interfaces/IENSRegistrarController.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

contract MockENSTest is Test {
    MockENS internal ens;
    MockERC20 internal token;

    address internal alice;
    address internal bob;

    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18);
        ens = new MockENS(address(token));
        vm.label(address(ens), "MockENS");

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // Helper function to create a registration struct
    function _createRegistration(
        string memory label,
        address owner,
        uint256 duration,
        bytes32 secret
    )
        internal
        pure
        returns (IETHRegistrarController.Registration memory)
    {
        bytes[] memory data = new bytes[](0);
        return IETHRegistrarController.Registration({
            label: label,
            owner: owner,
            duration: duration,
            secret: secret,
            resolver: address(0),
            data: data,
            reverseRecord: 0,
            referrer: bytes32(0)
        });
    }

    function testMakeCommitment() public {
        IETHRegistrarController.Registration memory registration =
            _createRegistration("alice", alice, 365 days, keccak256("secret"));

        bytes32 commitment = ens.makeCommitment(registration);
        bytes32 expectedCommitment = keccak256(abi.encode(registration));

        assertEq(commitment, expectedCommitment);
    }

    function testCommit() public {
        bytes32 commitment = keccak256("test-commitment");

        vm.prank(alice);
        ens.commit(commitment);

        uint256 commitmentTimestamp = ens.commitments(commitment);
        assertEq(commitmentTimestamp, block.timestamp);
    }

    function testCommitRevertsWhenAlreadyExists() public {
        bytes32 commitment = keccak256("test-commitment");

        vm.prank(alice);
        ens.commit(commitment);

        // Try to commit the same commitment again
        vm.prank(bob);
        vm.expectRevert();
        ens.commit(commitment);
    }

    function testRegister() public {
        IETHRegistrarController.Registration memory registration =
            _createRegistration("alice", alice, 365 days, keccak256("secret"));

        bytes32 commitment = ens.makeCommitment(registration);

        // First commit
        vm.prank(alice);
        ens.commit(commitment);

        // Wait for commitment to be valid (at least 1 minute)
        vm.warp(block.timestamp + 2 minutes);

        // Then register
        vm.prank(alice);
        ens.register{ value: 100 wei }(registration);

        // Check that the NFT was minted to alice
        bytes32 labelhash = keccak256(bytes(registration.label));
        uint256 tokenId = uint256(labelhash);

        assertEq(ens.ownerOf(tokenId), alice);
    }

    function testRegisterDeletesCommitment() public {
        IETHRegistrarController.Registration memory registration =
            _createRegistration("bob", bob, 365 days, keccak256("secret2"));

        bytes32 commitment = ens.makeCommitment(registration);

        // Commit
        vm.prank(bob);
        ens.commit(commitment);

        // Verify commitment exists
        assertGt(ens.commitments(commitment), 0);

        // Wait for commitment to be valid
        vm.warp(block.timestamp + 2 minutes);

        // Register
        vm.prank(bob);
        ens.register{ value: 100 wei }(registration);

        // Verify commitment was deleted
        assertEq(ens.commitments(commitment), 0);
    }

    function testRegisterStoresName() public {
        string memory label = "testname";
        IETHRegistrarController.Registration memory registration =
            _createRegistration(label, alice, 365 days, keccak256("secret3"));

        bytes32 commitment = ens.makeCommitment(registration);

        // Commit
        vm.prank(alice);
        ens.commit(commitment);

        // Wait for commitment to be valid
        vm.warp(block.timestamp + 2 minutes);

        // Register
        vm.prank(alice);
        ens.register{ value: 100 wei }(registration);

        // Check tokenURI returns the label
        bytes32 labelhash = keccak256(bytes(label));
        uint256 tokenId = uint256(labelhash);

        assertEq(ens.tokenURI(tokenId), label);
    }

    function testRegisterDifferentNames() public {
        // Register first name
        IETHRegistrarController.Registration memory registration1 =
            _createRegistration("first", alice, 365 days, keccak256("secret1"));

        bytes32 commitment1 = ens.makeCommitment(registration1);
        vm.prank(alice);
        ens.commit(commitment1);

        // Wait for commitment to be valid
        vm.warp(block.timestamp + 2 minutes);

        vm.prank(alice);
        ens.register{ value: 100 wei }(registration1);

        // Register second name
        IETHRegistrarController.Registration memory registration2 =
            _createRegistration("second", bob, 365 days, keccak256("secret2"));

        bytes32 commitment2 = ens.makeCommitment(registration2);
        vm.prank(bob);
        ens.commit(commitment2);

        // Wait for commitment to be valid
        vm.warp(block.timestamp + 2 minutes);

        vm.prank(bob);
        ens.register{ value: 100 wei }(registration2);

        // Verify both registrations
        bytes32 labelhash1 = keccak256(bytes("first"));
        bytes32 labelhash2 = keccak256(bytes("second"));

        assertEq(ens.ownerOf(uint256(labelhash1)), alice);
        assertEq(ens.ownerOf(uint256(labelhash2)), bob);
        assertEq(ens.tokenURI(uint256(labelhash1)), "first");
        assertEq(ens.tokenURI(uint256(labelhash2)), "second");
    }

    function testFuzzMakeCommitment(
        string memory label,
        address owner,
        uint256 duration,
        bytes32 secret
    )
        public
    {
        IETHRegistrarController.Registration memory registration =
            _createRegistration(label, owner, duration, secret);

        bytes32 commitment = ens.makeCommitment(registration);
        bytes32 expectedCommitment = keccak256(abi.encode(registration));

        assertEq(commitment, expectedCommitment);
    }

    function testFuzzCommitAndRegister(
        string memory label,
        address owner,
        uint256 duration,
        bytes32 secret
    )
        public
    {
        vm.assume(owner != address(0));
        vm.assume(bytes(label).length > 0);

        vm.deal(owner, 1 ether);

        IETHRegistrarController.Registration memory registration =
            _createRegistration(label, owner, duration, secret);

        bytes32 commitment = ens.makeCommitment(registration);

        // Commit
        vm.prank(owner);
        ens.commit(commitment);

        // Wait for commitment to be valid
        vm.warp(block.timestamp + 2 minutes);

        // Register
        vm.prank(owner);
        ens.register{ value: 100 wei }(registration);

        // Verify registration
        bytes32 labelhash = keccak256(bytes(label));
        uint256 tokenId = uint256(labelhash);

        assertEq(ens.ownerOf(tokenId), owner);
        assertEq(ens.tokenURI(tokenId), label);
        assertEq(ens.commitments(commitment), 0);
    }
}

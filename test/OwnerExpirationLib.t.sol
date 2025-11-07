// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { OwnerExpirationLib } from "../src/validator/OwnerExpirationLib.sol";

contract OwnerExpirationLibTest is Test {
    using OwnerExpirationLib for *;

    function testPackAndUnpackOwner() public pure {
        address owner = address(0x1234567890123456789012345678901234567890);
        uint48 expiration = 1_234_567_890;

        bytes32 packed = OwnerExpirationLib.packWithExpiration(owner, expiration);
        address unpackedOwner = OwnerExpirationLib.unpackOwner(packed);

        assertEq(unpackedOwner, owner, "Owner should match");
    }

    function testPackAndUnpackOwnerAndExpiration() public pure {
        address owner = address(0xabCDeF0123456789AbcdEf0123456789aBCDEF01);
        uint48 expiration = 281_474_976_710_655; // Max uint48

        bytes32 packed = OwnerExpirationLib.packWithExpiration(owner, expiration);
        (address unpackedOwner, uint48 unpackedExpiration) =
            OwnerExpirationLib.unpackOwnerAndExpiration(packed);

        assertEq(unpackedOwner, owner, "Owner should match");
        assertEq(unpackedExpiration, expiration, "Expiration should match");
    }

    function testPackWithZeroValues() public pure {
        address owner = address(0);
        uint48 expiration = 0;

        bytes32 packed = OwnerExpirationLib.packWithExpiration(owner, expiration);
        (address unpackedOwner, uint48 unpackedExpiration) =
            OwnerExpirationLib.unpackOwnerAndExpiration(packed);

        assertEq(unpackedOwner, address(0), "Owner should be zero");
        assertEq(unpackedExpiration, 0, "Expiration should be zero");
        assertEq(packed, bytes32(0), "Packed value should be zero");
    }

    function testPackWithMaxValues() public pure {
        address owner = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        uint48 expiration = type(uint48).max;

        bytes32 packed = OwnerExpirationLib.packWithExpiration(owner, expiration);
        (address unpackedOwner, uint48 unpackedExpiration) =
            OwnerExpirationLib.unpackOwnerAndExpiration(packed);

        assertEq(unpackedOwner, owner, "Owner should match max address");
        assertEq(unpackedExpiration, expiration, "Expiration should match max uint48");
    }

    function testFuzz_PackAndUnpack(address owner, uint48 expiration) public pure {
        bytes32 packed = OwnerExpirationLib.packWithExpiration(owner, expiration);
        (address unpackedOwner, uint48 unpackedExpiration) =
            OwnerExpirationLib.unpackOwnerAndExpiration(packed);

        assertEq(unpackedOwner, owner, "Fuzzed owner should match");
        assertEq(unpackedExpiration, expiration, "Fuzzed expiration should match");
    }

    function testFuzz_UnpackOwner(address owner, uint48 expiration) public pure {
        bytes32 packed = OwnerExpirationLib.packWithExpiration(owner, expiration);
        address unpackedOwner = OwnerExpirationLib.unpackOwner(packed);

        assertEq(unpackedOwner, owner, "Fuzzed owner should match when using unpackOwner");
    }
}

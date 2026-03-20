// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { RhinestoneModuleKit, ModuleKitHelpers, AccountInstance } from "modulekit/ModuleKit.sol";
import { MODULE_TYPE_VALIDATOR } from "modulekit/accounts/common/interfaces/IERC7579Module.sol";
import { HCAModule } from "src/hca-module/HCAModule.sol";
import { OwnableValidator } from "src/hca-module/base/OwnableValidator.sol";
import { PackedUserOperation } from "modulekit/external/ERC4337.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { LibSort } from "solady/utils/LibSort.sol";
import { ERC7579ValidatorBase } from "modulekit/Modules.sol";

contract OwnableValidatorTest is RhinestoneModuleKit, Test {
    using ModuleKitHelpers for *;
    using LibSort for *;

    // account and modules
    AccountInstance internal instance;
    HCAModule internal validator;

    // Test data
    uint256[] internal _ownerPks;
    address[] internal _owners;
    uint256 internal _threshold;

    function setUp() public {
        init();

        // Create the validator
        validator = new HCAModule();
        vm.label(address(validator), "OwnableValidator");

        // Set up test owners
        _threshold = 2;
        _ownerPks = new uint256[](3);
        _ownerPks[0] = 1;
        _ownerPks[1] = 2;
        _ownerPks[2] = 3;

        _owners = new address[](3);
        _owners[0] = vm.addr(_ownerPks[0]);
        _owners[1] = vm.addr(_ownerPks[1]);
        _owners[2] = vm.addr(_ownerPks[2]);

        // Sort owners
        _owners.sort();
    }

    /* //////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _getEmptyUserOp() internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(0),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });
    }

    function _signUserOpHash(
        uint256 privateKey,
        bytes32 userOpHash
    )
        internal
        pure
        returns (bytes memory)
    {
        bytes32 ethSignedHash = ECDSA.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signHash(uint256 privateKey, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hash);
        return abi.encodePacked(r, s, v);
    }

    function _createOwnersWithExpiration(
        address[] memory addrs,
        uint48 expiration
    )
        internal
        pure
        returns (OwnableValidator.Owner[] memory)
    {
        OwnableValidator.Owner[] memory ownersWithExp = new OwnableValidator.Owner[](addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            ownersWithExp[i] = OwnableValidator.Owner({ addr: addrs[i], expiration: expiration });
        }
        return ownersWithExp;
    }

    /* //////////////////////////////////////////////////////////////////////////
                                    INSTALLATION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_OnInstallWhenOwnersIncludeNoDuplicates() public {
        // it should set threshold
        // it should add owners
        // it should emit event

        OwnableValidator.Owner[] memory ownersWithExp =
            _createOwnersWithExpiration(_owners, type(uint48).max); //0
        // = no expiration
        bytes memory data = abi.encode(_threshold, ownersWithExp);

        vm.expectEmit(true, true, true, true);
        emit OwnableValidator.ModuleInitialized(address(this));

        validator.onInstall(data);

        uint256 threshold = validator.thresholds(address(this));
        assertEq(threshold, _threshold);

        uint256 ownerCount = validator.getOwnersCount(address(this));
        assertEq(ownerCount, _owners.length);

        for (uint256 i = 0; i < _owners.length; i++) {
            assertTrue(validator.isOwner(address(this), _owners[i]));
        }
    }

    function test_OnInstallWithExpiringOwners() public {
        // it should set owners with expiration timestamps
        // HCAModule requires first owner to have permanent expiration

        uint48 expiration = uint48(block.timestamp + 1 days);
        OwnableValidator.Owner[] memory ownersWithExp =
            _createOwnersWithExpiration(_owners, expiration);
        // First owner must be permanent per HCAModule rules
        ownersWithExp[0].expiration = type(uint48).max;
        bytes memory data = abi.encode(_threshold, ownersWithExp);

        validator.onInstall(data);

        // First owner should be permanent
        assertEq(validator.getOwnerExpiration(address(this), _owners[0]), type(uint48).max);
        // Other owners should have the expiration
        for (uint256 i = 1; i < _owners.length; i++) {
            uint48 ownerExpiration = validator.getOwnerExpiration(address(this), _owners[i]);
            assertEq(ownerExpiration, expiration);
        }
    }

    function test_OnInstallRevertWhen_ModuleIsAlreadyInitialized() public {
        // it should revert
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        OwnableValidator.Owner[] memory ownersWithExp =
            _createOwnersWithExpiration(_owners, type(uint48).max);
        bytes memory data = abi.encode(_threshold, ownersWithExp);

        vm.expectRevert();
        validator.onInstall(data);
    }

    function test_OnInstallRevertWhen_ThresholdIsZero() public {
        // it should revert
        OwnableValidator.Owner[] memory ownersWithExp =
            _createOwnersWithExpiration(_owners, type(uint48).max);
        bytes memory data = abi.encode(0, ownersWithExp);

        vm.expectRevert();
        validator.onInstall(data);
    }

    function test_OnInstallRevertWhen_OwnersLengthIsLessThanThreshold() public {
        // it should revert
        address[] memory singleOwner = new address[](1);
        singleOwner[0] = _owners[0];

        OwnableValidator.Owner[] memory ownersWithExp =
            _createOwnersWithExpiration(singleOwner, type(uint48).max);
        bytes memory data = abi.encode(2, ownersWithExp); // threshold > owners.length

        vm.expectRevert();
        validator.onInstall(data);
    }

    /* //////////////////////////////////////////////////////////////////////////
                                    UNINSTALLATION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_OnUninstallShouldResetThreshold() public {
        // it should set threshold to 0
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        validator.onUninstall("");

        uint256 threshold = validator.thresholds(address(this));
        assertEq(threshold, 0);
    }

    function test_OnUninstallShouldSetOwnerCountTo0() public {
        // it should set owner count to 0
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        validator.onUninstall("");

        uint256 ownerCount = validator.getOwnersCount(address(this));
        assertEq(ownerCount, 0);
    }

    /* //////////////////////////////////////////////////////////////////////////
                                    INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_IsInitializedWhenModuleIsNotInitialized() public view {
        // it should return false
        bool isInitialized = validator.isInitialized(address(this));
        assertFalse(isInitialized);
    }

    function test_IsInitializedWhenModuleIsInitialized() public {
        // it should return true
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        bool isInitialized = validator.isInitialized(address(this));
        assertTrue(isInitialized);
    }

    /* //////////////////////////////////////////////////////////////////////////
                                    UPDATE CONFIG TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_UpdateConfigRevertWhen_ModuleIsNotInitialized() public {
        // it should revert
        OwnableValidator.Owner[] memory emptyOwners = new OwnableValidator.Owner[](0);
        address[] memory emptyRemove = new address[](0);

        vm.expectRevert();
        validator.updateConfig(1, emptyOwners, emptyRemove);
    }

    function test_UpdateConfigShouldUpdateThreshold() public {
        // it should update threshold
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        OwnableValidator.Owner[] memory emptyOwners = new OwnableValidator.Owner[](0);
        address[] memory emptyRemove = new address[](0);

        validator.updateConfig(3, emptyOwners, emptyRemove);

        uint256 threshold = validator.thresholds(address(this));
        assertEq(threshold, 3);
    }

    function test_UpdateConfigShouldAddOwners() public {
        // it should add owners
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        address newOwner = vm.addr(100);
        address[] memory newOwners = new address[](1);
        newOwners[0] = newOwner;

        OwnableValidator.Owner[] memory ownersWithExp =
            _createOwnersWithExpiration(newOwners, type(uint48).max);
        address[] memory emptyRemove = new address[](0);

        validator.updateConfig(_threshold, ownersWithExp, emptyRemove);

        assertTrue(validator.isOwner(address(this), newOwner));
        assertEq(validator.getOwnersCount(address(this)), _owners.length + 1);
    }

    function test_UpdateConfigShouldRemoveOwners() public {
        // it should remove owners
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        address[] memory ownersToRemove = new address[](1);
        ownersToRemove[0] = _owners[0];

        OwnableValidator.Owner[] memory emptyOwners = new OwnableValidator.Owner[](0);

        validator.updateConfig(_threshold, emptyOwners, ownersToRemove);

        assertFalse(validator.isOwner(address(this), _owners[0]));
        assertEq(validator.getOwnersCount(address(this)), _owners.length - 1);
    }

    /* //////////////////////////////////////////////////////////////////////////
                                    EXPIRATION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_UpdateOwnerExpiration() public {
        // it should update the expiration timestamp
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        uint48 newExpiration = uint48(block.timestamp + 7 days);
        validator.updateOwnerExpiration(_owners[0], newExpiration);

        uint48 expiration = validator.getOwnerExpiration(address(this), _owners[0]);
        assertEq(expiration, newExpiration);
    }

    function test_UpdateOwnerExpirationRevertWhen_OwnerDoesNotExist() public {
        // it should revert
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        address nonExistentOwner = vm.addr(999);
        uint48 newExpiration = uint48(block.timestamp + 7 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableValidator.OwnerNotFound.selector, address(this), nonExistentOwner
            )
        );
        validator.updateOwnerExpiration(nonExistentOwner, newExpiration);
    }

    function test_ValidateUserOpRevertWhen_OwnerIsExpired() public {
        // it should return VALIDATION_FAILED
        uint48 expiration = uint48(block.timestamp + 1 hours);
        OwnableValidator.Owner[] memory ownersWithExp =
            _createOwnersWithExpiration(_owners, expiration);
        ownersWithExp[0].expiration = type(uint48).max; // first owner must be permanent
        bytes memory data = abi.encode(_threshold, ownersWithExp);
        validator.onInstall(data);

        // Warp past expiration
        vm.warp(block.timestamp + 2 hours);

        PackedUserOperation memory userOp = _getEmptyUserOp();
        userOp.sender = address(this);
        bytes32 userOpHash = keccak256("userOpHash");

        bytes memory signature1 = _signUserOpHash(_ownerPks[0], userOpHash);
        bytes memory signature2 = _signUserOpHash(_ownerPks[1], userOpHash);
        userOp.signature = abi.encodePacked(signature1, signature2);

        ERC7579ValidatorBase.ValidationData validationData =
            validator.validateUserOp(userOp, userOpHash);
        assertEq(ERC7579ValidatorBase.ValidationData.unwrap(validationData), 1); // VALIDATION_FAILED
    }

    function test_ValidateUserOpWhenOwnerIsNotExpired() public {
        // it should return VALIDATION_SUCCESS
        uint48 expiration = uint48(block.timestamp + 1 hours);
        OwnableValidator.Owner[] memory ownersWithExp =
            _createOwnersWithExpiration(_owners, expiration);
        ownersWithExp[0].expiration = type(uint48).max; // first owner must be permanent
        bytes memory data = abi.encode(_threshold, ownersWithExp);
        validator.onInstall(data);

        PackedUserOperation memory userOp = _getEmptyUserOp();
        userOp.sender = address(this);
        bytes32 userOpHash = keccak256("userOpHash");

        bytes memory signature1 = _signUserOpHash(_ownerPks[0], userOpHash);
        bytes memory signature2 = _signUserOpHash(_ownerPks[1], userOpHash);
        userOp.signature = abi.encodePacked(signature1, signature2);

        ERC7579ValidatorBase.ValidationData validationData =
            validator.validateUserOp(userOp, userOpHash);
        assertEq(ERC7579ValidatorBase.ValidationData.unwrap(validationData), 0); // VALIDATION_SUCCESS
    }

    /* //////////////////////////////////////////////////////////////////////////
                                    SIGNATURE VALIDATION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_ValidateUserOpRevertWhen_ThresholdIsNotSet() public {
        // it should return VALIDATION_FAILED
        PackedUserOperation memory userOp = _getEmptyUserOp();
        userOp.sender = address(this);
        bytes32 userOpHash = keccak256("userOpHash");

        ERC7579ValidatorBase.ValidationData validationData =
            validator.validateUserOp(userOp, userOpHash);
        assertEq(ERC7579ValidatorBase.ValidationData.unwrap(validationData), 1); // VALIDATION_FAILED
    }

    function test_ValidateUserOpWhenTheSignaturesAreNotValid() public {
        // it should return VALIDATION_FAILED
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        PackedUserOperation memory userOp = _getEmptyUserOp();
        userOp.sender = address(this);
        bytes32 userOpHash = keccak256("userOpHash");

        // Sign with wrong keys
        bytes memory signature1 = _signUserOpHash(999, userOpHash);
        bytes memory signature2 = _signUserOpHash(998, userOpHash);
        userOp.signature = abi.encodePacked(signature1, signature2);

        ERC7579ValidatorBase.ValidationData validationData =
            validator.validateUserOp(userOp, userOpHash);
        assertEq(ERC7579ValidatorBase.ValidationData.unwrap(validationData), 1); // VALIDATION_FAILED
    }

    function test_ValidateUserOpWhenUniqueSignaturesAreLessThanThreshold() public {
        // it should revert with InvalidSignature (library checks threshold)
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        PackedUserOperation memory userOp = _getEmptyUserOp();
        userOp.sender = address(this);
        bytes32 userOpHash = keccak256("userOpHash");

        // Only 1 signature when threshold is 2
        bytes memory signature1 = _signUserOpHash(_ownerPks[0], userOpHash);
        userOp.signature = signature1;

        // CheckSignatures library will revert if not enough signatures
        vm.expectRevert();
        validator.validateUserOp(userOp, userOpHash);
    }

    function test_ValidateUserOpWhenTheUniqueSignaturesAreGreaterThanThreshold() public {
        // it should return VALIDATION_SUCCESS
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        PackedUserOperation memory userOp = _getEmptyUserOp();
        userOp.sender = address(this);
        bytes32 userOpHash = keccak256("userOpHash");

        bytes memory signature1 = _signUserOpHash(_ownerPks[0], userOpHash);
        bytes memory signature2 = _signUserOpHash(_ownerPks[1], userOpHash);
        userOp.signature = abi.encodePacked(signature1, signature2);

        ERC7579ValidatorBase.ValidationData validationData =
            validator.validateUserOp(userOp, userOpHash);
        assertEq(ERC7579ValidatorBase.ValidationData.unwrap(validationData), 0); // VALIDATION_SUCCESS
    }

    /* //////////////////////////////////////////////////////////////////////////
                                    EIP-1271 TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_IsValidSignatureWithSenderWhenThresholdIsNotSet() public {
        // it should return EIP1271_FAILED
        bytes32 hash = keccak256("hash");
        bytes memory signatures = "";

        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signatures);
        assertEq(result, bytes4(0xffffffff)); // EIP1271_FAILED
    }

    function test_IsValidSignatureWithSenderWhenTheSignaturesAreNotValid() public {
        // it should return EIP1271_FAILED
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        bytes32 hash = keccak256("hash");
        bytes memory signature1 = _signHash(999, hash);
        bytes memory signature2 = _signHash(998, hash);
        bytes memory signatures = abi.encodePacked(signature1, signature2);

        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signatures);
        assertEq(result, bytes4(0xffffffff)); // EIP1271_FAILED
    }

    function test_IsValidSignatureWithSenderWhenUniqueSignaturesAreLessThanThreshold() public {
        // it should revert with InvalidSignature (library checks threshold)
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        bytes32 hash = keccak256("hash");
        bytes memory signature1 = _signHash(_ownerPks[0], hash);

        // CheckSignatures library will revert if not enough signatures
        vm.expectRevert();
        validator.isValidSignatureWithSender(address(0), hash, signature1);
    }

    function test_IsValidSignatureWithSenderWhenUniqueSignaturesAreGreaterThanThreshold() public {
        // it should return EIP1271_SUCCESS
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        bytes32 hash = keccak256("hash");
        bytes memory signature1 = _signHash(_ownerPks[0], hash);
        bytes memory signature2 = _signHash(_ownerPks[1], hash);
        bytes memory signatures = abi.encodePacked(signature1, signature2);

        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signatures);
        assertEq(result, bytes4(0x1626ba7e)); // EIP1271_SUCCESS
    }

    /* //////////////////////////////////////////////////////////////////////////
                                    STATELESS VALIDATION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_ValidateSignatureWithDataWhenOwnersAreNotUnique() public {
        // it should return false
        address[] memory duplicateAddrs = new address[](3);
        duplicateAddrs[0] = _owners[0];
        duplicateAddrs[1] = _owners[0]; // duplicate
        duplicateAddrs[2] = _owners[1];

        OwnableValidator.Owner[] memory duplicateOwners =
            _createOwnersWithExpiration(duplicateAddrs, type(uint48).max);

        bytes32 hash = keccak256("hash");
        bytes memory signatures = "";
        bytes memory data = abi.encode(_threshold, duplicateOwners);

        bool isValid = validator.validateSignatureWithData(hash, signatures, data);
        assertFalse(isValid);
    }

    function test_ValidateSignatureWithDataWhenThresholdIsNotSet() public {
        // it should return false
        OwnableValidator.Owner[] memory ownersWithExp =
            _createOwnersWithExpiration(_owners, type(uint48).max);

        bytes32 hash = keccak256("hash");
        bytes memory signatures = "";
        bytes memory data = abi.encode(0, ownersWithExp);

        bool isValid = validator.validateSignatureWithData(hash, signatures, data);
        assertFalse(isValid);
    }

    function test_ValidateSignatureWithDataWhenTheSignaturesAreNotValid() public {
        // it should return false
        OwnableValidator.Owner[] memory ownersWithExp =
            _createOwnersWithExpiration(_owners, type(uint48).max);

        bytes32 hash = keccak256("hash");
        bytes memory signature1 = _signHash(999, hash);
        bytes memory signature2 = _signHash(998, hash);
        bytes memory signatures = abi.encodePacked(signature1, signature2);
        bytes memory data = abi.encode(_threshold, ownersWithExp);

        bool isValid = validator.validateSignatureWithData(hash, signatures, data);
        assertFalse(isValid);
    }

    function test_ValidateSignatureWithDataWhenUniqueSignaturesAreLessThanThreshold() public {
        // it should return false
        OwnableValidator.Owner[] memory ownersWithExp =
            _createOwnersWithExpiration(_owners, type(uint48).max);

        bytes32 hash = keccak256("hash");
        bytes memory signature1 = _signHash(_ownerPks[0], hash);
        bytes memory data = abi.encode(_threshold, ownersWithExp);

        bool isValid = validator.validateSignatureWithData(hash, signature1, data);
        assertFalse(isValid);
    }

    function test_ValidateSignatureWithDataWhenUniqueSignaturesAreGreaterThanThreshold()
        public
        view
    {
        // it should return true
        // Manually create sorted owners to ensure proper order
        // Sorted order: 0x2B5A (pk2), 0x6813 (pk3), 0x7E5F (pk1)
        // validateSignatureWithData expects (uint256, address[]) not Owner[]
        address[] memory sortedOwners = new address[](3);
        sortedOwners[0] = vm.addr(2); // 0x2B5A...
        sortedOwners[1] = vm.addr(3); // 0x6813...
        sortedOwners[2] = vm.addr(1); // 0x7E5F...

        bytes32 hash = keccak256("hash");
        // Note: validateSignatureWithData does NOT use ECDSA.toEthSignedMessageHash
        // It validates the raw hash directly
        // Sign with pk2 and pk3 (first two in sorted order)
        bytes memory signature1 = _signHash(2, hash); // pk 2
        bytes memory signature2 = _signHash(3, hash); // pk 3
        bytes memory signatures = abi.encodePacked(signature1, signature2);
        bytes memory data = abi.encode(_threshold, sortedOwners);

        bool isValid = validator.validateSignatureWithData(hash, signatures, data);
        assertTrue(isValid);
    }

    /* //////////////////////////////////////////////////////////////////////////
                                    VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_GetOwners() public {
        // it should return all owners with expiration
        uint48 expiration = uint48(block.timestamp + 1 days);
        OwnableValidator.Owner[] memory ownersWithExp =
            _createOwnersWithExpiration(_owners, expiration);
        ownersWithExp[0].expiration = type(uint48).max; // first owner must be permanent
        bytes memory data = abi.encode(_threshold, ownersWithExp);
        validator.onInstall(data);

        OwnableValidator.Owner[] memory retrievedOwners = validator.getOwners(address(this));
        assertEq(retrievedOwners.length, _owners.length);

        for (uint256 i = 0; i < retrievedOwners.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < _owners.length; j++) {
                if (retrievedOwners[i].addr == _owners[j]) {
                    found = true;
                    // First owner (index 0 in _owners) is permanent
                    if (j == 0) {
                        assertEq(retrievedOwners[i].expiration, type(uint48).max);
                    } else {
                        assertEq(retrievedOwners[i].expiration, expiration);
                    }
                    break;
                }
            }
            assertTrue(found, "Owner should be found");
        }
    }

    function test_IsOwner() public {
        // it should return true for existing owners
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        for (uint256 i = 0; i < _owners.length; i++) {
            assertTrue(validator.isOwner(address(this), _owners[i]));
        }

        address nonOwner = vm.addr(999);
        assertFalse(validator.isOwner(address(this), nonOwner));
    }

    function test_GetOwnersCount() public {
        // it should return the correct count
        test_OnInstallWhenOwnersIncludeNoDuplicates();

        uint256 count = validator.getOwnersCount(address(this));
        assertEq(count, _owners.length);
    }

    function test_GetOwnerExpiration() public {
        // it should return the expiration timestamp
        uint48 expiration = uint48(block.timestamp + 1 days);
        OwnableValidator.Owner[] memory ownersWithExp =
            _createOwnersWithExpiration(_owners, expiration);
        ownersWithExp[0].expiration = type(uint48).max; // first owner must be permanent
        bytes memory data = abi.encode(_threshold, ownersWithExp);
        validator.onInstall(data);

        // First owner is permanent
        uint48 retrievedExpiration = validator.getOwnerExpiration(address(this), _owners[1]);
        assertEq(retrievedExpiration, expiration);
    }

    /* //////////////////////////////////////////////////////////////////////////
                                    MODULE TYPE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_IsModuleType() public view {
        // it should return true for TYPE_VALIDATOR
        assertTrue(validator.isModuleType(1)); // TYPE_VALIDATOR
        assertTrue(validator.isModuleType(7)); // TYPE_STATELESS_VALIDATOR
    }

    function test_Name() public view {
        // it should return the module name
        assertEq(validator.name(), "HCAModule");
    }

    function test_Version() public view {
        // it should return the module version
        assertEq(validator.version(), "2.0.0");
    }
}

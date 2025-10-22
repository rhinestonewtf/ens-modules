// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { ERC7579ValidatorBase } from "modulekit/Modules.sol";
import { PackedUserOperation } from "modulekit/external/ERC4337.sol";
import { LibSort } from "solady/utils/LibSort.sol";
import { CheckSignatures } from "checknsignatures/CheckNSignatures.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { EnumerableSet } from "@erc7579/enumerablemap4337/EnumerableSet4337.sol";
import {
    MODULE_TYPE_STATELESS_VALIDATOR as TYPE_STATELESS_VALIDATOR
} from "modulekit/module-bases/utils/ERC7579Constants.sol";
import { OwnerExpirationLib } from "./OwnerExpirationLib.sol";

contract ENSValidator is ERC7579ValidatorBase {
    using LibSort for *;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using OwnerExpirationLib for bytes32;
    using OwnerExpirationLib for address;

    // maximum number of owners per account
    uint256 constant MAX_OWNERS = 32;
    uint256 constant MIN_OWNERS = 1;

    struct Owner {
        address addr;
        uint48 expiration;
    }

    event ModuleInitialized(address indexed account);
    event ModuleUninitialized(address indexed account);
    event ThresholdSet(address indexed account, uint256 threshold);
    event OwnerAdded(address indexed account, address indexed owner);
    event OwnerRemoved(address indexed account, address indexed owner);

    error InvalidThreshold(uint256 threshold, uint256 minThreshold, uint256 maxThreshold);
    error InvalidOwnersCount(uint256 ownersCount, uint256 minOwnersCount, uint256 maxOwnersCount);

    EnumerableSet.Bytes32Set owners;
    mapping(address account => uint256) public thresholds;

    modifier moduleIsInitialized() {
        require(isInitialized(msg.sender), NotInitialized(msg.sender));
        _;
    }

    modifier moduleIsNotInitialized() {
        require(!isInitialized(msg.sender), ModuleAlreadyInitialized(msg.sender));
        _;
    }

    // Default to the min and max value constants for the invariants
    modifier checkInvariants() {
        _;
        _checkInvariants(msg.sender, MIN_OWNERS, MAX_OWNERS);
    }

    /* //////////////////////////////////////////////////////////////////////////
                                     INTERNAL
    //////////////////////////////////////////////////////////////////////////*/

    function _checkInvariants(address account, uint256 minOwnersCount, uint256 maxOwnersCount)
        internal
        view
    {
        uint256 ownersCount = owners.length(account);
        uint256 threshold = thresholds[account];
        require(
            minOwnersCount <= ownersCount && ownersCount <= maxOwnersCount,
            InvalidOwnersCount(ownersCount, minOwnersCount, maxOwnersCount)
        );
        require(
            minOwnersCount <= threshold && threshold <= ownersCount,
            InvalidThreshold(threshold, minOwnersCount, ownersCount)
        );
    }

    function _setThreshold(address account, uint256 _threshold) internal {
        thresholds[account] = _threshold;
        emit ThresholdSet(account, _threshold);
    }

    function _findOwnerElement(address account, address owner)
        internal
        view
        returns (bool found, bytes32 element)
    {
        bytes32[] memory values = owners.values(account);
        for (uint256 i = 0; i < values.length; i++) {
            address ownerAddr = values[i].unpackOwner();
            if (ownerAddr == owner) {
                return (true, values[i]);
            }
        }
        return (false, bytes32(0));
    }

    function _isOwnerValid(address account, address owner) internal view returns (bool) {
        (bool found, bytes32 element) = _findOwnerElement(account, owner);
        if (!found) return false;

        (, uint48 expiration) = element.unpackOwnerAndExpiration();
        // Check if not expired (expiration is in the future or 0 for no expiration)
        return expiration == 0 || block.timestamp < expiration;
    }

    function _addOwners(address account, Owner[] memory newOwners) internal {
        for (uint256 i = 0; i < newOwners.length; i++) {
            bytes32 element = newOwners[i].addr.toSetElement(newOwners[i].expiration);
            if (owners.add(account, element)) emit OwnerAdded(account, newOwners[i].addr);
        }
    }

    function _removeOwners(address account, address[] memory ownersToRemove) internal {
        for (uint256 i = 0; i < ownersToRemove.length; i++) {
            (bool found, bytes32 element) = _findOwnerElement(account, ownersToRemove[i]);
            if (found && owners.remove(account, element)) {
                emit OwnerRemoved(account, ownersToRemove[i]);
            }
        }
    }

    function _updateConfig(
        uint256 newThreshold,
        Owner[] memory ownersToAdd,
        address[] memory ownersToRemove
    )
        internal
        checkInvariants
        moduleIsInitialized
    {
        address account = msg.sender;
        _removeOwners(account, ownersToRemove);
        _addOwners(account, ownersToAdd);
        _setThreshold(account, newThreshold);
    }

    /* //////////////////////////////////////////////////////////////////////////
                                PUBLIC
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Updates the config for the account.
     * This function is not idempotent.
     * @param newThreshold uint256 threshold to set
     * @param ownersToAdd Owner[] array of owners to add with their expiration timestamps.
     * @param ownersToRemove address[] array of owners to remove.
     */
    function updateConfig(
        uint256 newThreshold,
        Owner[] calldata ownersToAdd,
        address[] calldata ownersToRemove
    )
        public
    {
        _updateConfig(newThreshold, ownersToAdd, ownersToRemove);
    }

    /**
     * Updates the expiration time for an existing owner.
     * @param owner address of the owner to update
     * @param newExpiration uint48 new expiration timestamp
     */
    function updateOwnerExpiration(address owner, uint48 newExpiration) public moduleIsInitialized {
        address account = msg.sender;
        (bool found, bytes32 oldElement) = _findOwnerElement(account, owner);

        require(found, "Owner does not exist");

        // Remove old element and add new one with updated expiration
        owners.remove(account, oldElement);
        bytes32 newElement = owner.toSetElement(newExpiration);
        owners.add(account, newElement);
    }

    function onInstall(bytes calldata data)
        external
        override
        moduleIsNotInitialized
        checkInvariants
    {
        address account = msg.sender;
        (uint256 threshold, Owner[] memory newOwners) = abi.decode(data, (uint256, Owner[]));

        _addOwners(account, newOwners);
        _setThreshold(account, threshold);

        emit ModuleInitialized(account);
    }

    function onUninstall(bytes calldata) external override {
        address account = msg.sender;

        // Get all owners and extract addresses for removal
        Owner[] memory currentOwners = getOwners(account);
        address[] memory ownersToRemove = new address[](currentOwners.length);
        for (uint256 i = 0; i < currentOwners.length; i++) {
            ownersToRemove[i] = currentOwners[i].addr;
        }

        _removeOwners(account, ownersToRemove);
        _setThreshold(account, 0);
        _checkInvariants(account, 0, 0);

        emit ModuleUninitialized(msg.sender);
    }

    // ** VIEW FUNCTIONS ** //

    function isInitialized(address smartAccount) public view returns (bool) {
        return thresholds[smartAccount] != 0;
    }

    function getOwners(address account) public view returns (Owner[] memory ownersArray) {
        bytes32[] memory elements = owners.values(account);
        ownersArray = new Owner[](elements.length);
        for (uint256 i = 0; i < elements.length; i++) {
            (address ownerAddr, uint48 expiration) = elements[i].unpackOwnerAndExpiration();
            ownersArray[i] = Owner(ownerAddr, expiration);
        }
    }

    function isOwner(address account, address owner) public view returns (bool) {
        (bool found,) = _findOwnerElement(account, owner);
        return found;
    }

    function getOwnersCount(address account) public view returns (uint256) {
        return owners.length(account);
    }

    function getOwnerExpiration(address account, address owner) public view returns (uint48) {
        (bool found, bytes32 element) = _findOwnerElement(account, owner);
        if (!found) return 0;
        (, uint48 expiration) = element.unpackOwnerAndExpiration();
        return expiration;
    }

    /* //////////////////////////////////////////////////////////////////////////////////////
            EVERYTHING BEYOND THIS POINT IS EXACTLY THE SAME AS THE OWNABLE VALIDATOR
    //////////////////////////////////////////////////////////////////////////////////////*/

    /**
     * Validates a user operation
     *
     * @param userOp PackedUserOperation struct containing the UserOperation
     * @param userOpHash bytes32 hash of the UserOperation
     *
     * @return ValidationData the UserOperation validation result
     */
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash)
        external
        view
        override
        returns (ValidationData)
    {
        // validate the signature with the config
        bool isValid = _validateSignatureWithConfig(
            userOp.sender, ECDSA.toEthSignedMessageHash(userOpHash), userOp.signature
        );

        // return the result
        if (isValid) {
            return VALIDATION_SUCCESS;
        }
        return VALIDATION_FAILED;
    }

    /**
     * Validates an ERC-1271 signature with the sender
     *
     * @param hash bytes32 hash of the data
     * @param data bytes data containing the signatures
     *
     * @return bytes4 EIP1271_SUCCESS if the signature is valid, EIP1271_FAILED otherwise
     */
    function isValidSignatureWithSender(address, bytes32 hash, bytes calldata data)
        external
        view
        override
        returns (bytes4)
    {
        // Validate with raw hash for EIP-712 signatures
        bool isValid = _validateSignatureWithConfig(msg.sender, hash, data);

        // return the result
        if (isValid) {
            return EIP1271_SUCCESS;
        }
        return EIP1271_FAILED;
    }

    /**
     * Validates a signature with the data (stateless validation)
     *
     * @param hash bytes32 hash of the data
     * @param signature bytes data containing the signatures
     * @param data bytes data containing the data
     *
     * @return bool true if the signature is valid, false otherwise
     */
    function validateSignatureWithData(bytes32 hash, bytes calldata signature, bytes calldata data)
        external
        view
        returns (bool)
    {
        // decode the threshold and owners
        (uint256 _threshold, address[] memory _owners) = abi.decode(data, (uint256, address[]));

        // check that owners are sorted and uniquified
        if (!_owners.isSortedAndUniquified()) {
            return false;
        }

        // check that threshold is set
        if (_threshold == 0) {
            return false;
        }

        // recover the signers from the signatures
        address[] memory signers = CheckSignatures.recoverNSignatures(hash, signature, _threshold);

        // sort and uniquify the signers to make sure a signer is not reused
        signers.sort();
        signers.uniquifySorted();

        // check if the signers are owners
        uint256 validSigners;
        uint256 signersLength = signers.length;
        for (uint256 i = 0; i < signersLength; i++) {
            (bool found,) = _owners.searchSorted(signers[i]);
            if (found) {
                validSigners++;
            }
        }

        // check if the threshold is met and return the result
        if (validSigners >= _threshold) {
            // if the threshold is met, return true
            return true;
        }
        // if the threshold is not met, false
        return false;
    }

    function _validateSignatureWithConfig(address account, bytes32 hash, bytes calldata data)
        internal
        view
        returns (bool)
    {
        // get the threshold and check that its set
        uint256 _threshold = thresholds[account];
        if (_threshold == 0) {
            return false;
        }

        // recover the signers from the signatures
        address[] memory signers = CheckSignatures.recoverNSignatures(hash, data, _threshold);

        // sort and uniquify the signers to make sure a signer is not reused
        signers.sort();
        signers.uniquifySorted();

        // check if the signers are owners and not expired
        uint256 validSigners;
        uint256 signersLength = signers.length;
        for (uint256 i = 0; i < signersLength; i++) {
            if (_isOwnerValid(account, signers[i])) {
                validSigners++;
            }
        }

        // check if the threshold is met and return the result
        if (validSigners >= _threshold) {
            // if the threshold is met, return true
            return true;
        }
        // if the threshold is not met, return false
        return false;
    }

    /* //////////////////////////////////////////////////////////////////////////
                                     METADATA
    //////////////////////////////////////////////////////////////////////////*/

    function isModuleType(uint256 typeID) external pure override returns (bool) {
        return typeID == TYPE_VALIDATOR || typeID == TYPE_STATELESS_VALIDATOR;
    }

    function name() external pure virtual returns (string memory) {
        return "OwnableValidator";
    }

    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }
}

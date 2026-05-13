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
import { OwnerExpirationLib } from "./lib/OwnerExpirationLib.sol";
import { ERC7739Validator } from "erc7739Validator/ERC7739Validator.sol";

/**
 * @title OwnerableValidator
 * @notice ERC7579 validator module implementing multi-signature validation with time-based owner
 * expiration
 * @dev This contract provides both stateful and stateless signature validation modes for smart
 * accounts.
 *      It extends ERC7579ValidatorBase to provide multi-signature validation with a configurable
 * threshold
 *      and time-based owner expiration functionality.
 *
 * Key Features:
 * - Multi-signature validation with configurable threshold (k-of-n signatures required)
 * - Time-based owner expiration mechanism for automatic access revocation
 * - Dual validation modes: stateful (using stored config) and stateless (config passed with
 * signature)
 * - EIP-1271 signature validation support for off-chain signature verification
 * - Per-account owner management using EnumerableSet for gas-efficient storage
 *
 * Owner Storage:
 * Owners are stored as packed bytes32 values in an EnumerableSet, where each element contains:
 * - Owner address (160 bits)
 * - Expiration timestamp (48 bits) - type(uint48).max means permanent/no expiration
 * - Unused space (48 bits)
 * This packing strategy optimizes storage costs while maintaining efficient lookups.
 *
 * Validation Modes:
 * 1. Stateful (validateUserOp, isValidSignatureWithSender): Uses stored threshold and owners
 * 2. Stateless (validateSignatureWithData): Accepts threshold and owners as calldata, useful for
 *    signature validation before module installation or for off-chain verification
 *
 * @custom:security This contract implements several security measures:
 * - Signature uniqueness: Prevents signature reuse by sorting and uniquifying recovered signers
 * - Expiration checks: Automatically invalidates expired owners during validation
 * - Invariant checks: Ensures threshold is always valid relative to owner count
 * - Owner count limits: Enforces MIN_OWNERS (1) and MAX_OWNERS (32) constraints
 */
contract OwnableValidator is ERC7579ValidatorBase, ERC7739Validator {
    using LibSort for *;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using OwnerExpirationLib for bytes32;
    using OwnerExpirationLib for address;

    /* //////////////////////////////////////////////////////////////////////////
                                     CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Maximum number of owners allowed per account
     * @dev Set to 32 to balance security (enough signers for decentralization) with gas costs
     *      (iteration over owners in validation). This limit prevents DoS via excessive owners.
     */
    uint256 constant MAX_OWNERS = 32;

    /**
     * @notice Minimum number of owners required per account
     * @dev Set to 1 to ensure at least one owner exists for account recovery and operations
     */
    uint256 constant MIN_OWNERS = 1;

    /* //////////////////////////////////////////////////////////////////////////
                                     TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Represents an owner with an optional expiration timestamp
     * @dev Used for initialization and configuration updates
     * @param addr The owner's Ethereum address
     * @param expiration Unix timestamp when owner access expires (type(uint48).max =
     * permanent/never expires)
     */
    struct Owner {
        address addr;
        uint48 expiration;
    }

    /* //////////////////////////////////////////////////////////////////////////
                                     EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the module is installed for an account
     * @param account The smart account address that installed this module
     */
    event ModuleInitialized(address indexed account);

    /**
     * @notice Emitted when the module is uninstalled from an account
     * @param account The smart account address that uninstalled this module
     */
    event ModuleUninitialized(address indexed account);

    /**
     * @notice Emitted when the signature threshold is updated for an account
     * @param account The smart account address
     * @param threshold The new signature threshold (number of signatures required)
     */
    event ThresholdSet(address indexed account, uint256 threshold);

    /**
     * @notice Emitted when an owner is added to an account
     * @param account The smart account address
     * @param owner The address of the added owner
     */
    event OwnerAdded(address indexed account, address indexed owner);

    /**
     * @notice Emitted when an owner is removed from an account
     * @param account The smart account address
     * @param owner The address of the removed owner
     */
    event OwnerRemoved(address indexed account, address indexed owner);

    error OwnerNotFound(address account, address owner);

    /**
     * @notice Emitted when an owner's expiration timestamp is updated
     * @param account The smart account address
     * @param owner The address of the owner whose expiration was updated
     * @param newExpiration The new expiration timestamp
     */
    event OwnerExpirationUpdated(
        address indexed account, address indexed owner, uint48 newExpiration
    );

    /* //////////////////////////////////////////////////////////////////////////
                                     ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Thrown when threshold value is invalid relative to owner count
     * @param threshold The invalid threshold value
     * @param minThreshold Minimum allowed threshold (usually MIN_OWNERS or threshold lower bound)
     * @param maxThreshold Maximum allowed threshold (usually current owner count)
     */
    error InvalidThreshold(uint256 threshold, uint256 minThreshold, uint256 maxThreshold);

    /**
     * @notice Thrown when owner count is outside allowed bounds
     * @param ownersCount The invalid owner count
     * @param minOwnersCount Minimum allowed owners (MIN_OWNERS)
     * @param maxOwnersCount Maximum allowed owners (MAX_OWNERS)
     */
    error InvalidOwnersCount(uint256 ownersCount, uint256 minOwnersCount, uint256 maxOwnersCount);

    /**
     * @notice Thrown when attempting to add the zero address as an owner
     */
    error ZeroAddressNotAllowed();

    /**
     * @notice Thrown when expiration timestamp is in the past (excluding type(uint48).max for
     * permanent)
     * @param expiration The invalid expiration timestamp
     */
    error ExpirationInPast(uint48 expiration);

    /* //////////////////////////////////////////////////////////////////////////
                                     STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Stores packed owner data (address + expiration) for all accounts
     *      Uses EnumerableSet.Bytes32Set where each bytes32 element contains:
     *      - bits 256-97: owner address (160 bits)
     *      - bits 96-49: expiration timestamp (48 bits)
     *      - bits 48-1: unused (48 bits)
     *      The set is namespaced per account address for efficient per-account iteration
     */
    EnumerableSet.Bytes32Set owners;

    /**
     * @notice Maps each account to its required signature threshold
     * @dev A threshold of 0 indicates the module is not initialized for that account
     *      Valid thresholds must satisfy: MIN_OWNERS <= threshold <= owner_count
     */
    mapping(address account => uint256) public thresholds;

    /* //////////////////////////////////////////////////////////////////////////
                                     MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Ensures the module is initialized for msg.sender before executing the function
     *      Reverts with NotInitialized if threshold is 0 (indicating uninitialized state)
     */
    modifier moduleIsInitialized() {
        require(isInitialized(msg.sender), NotInitialized(msg.sender));
        _;
    }

    /**
     * @dev Ensures the module is not already initialized for msg.sender
     *      Reverts with ModuleAlreadyInitialized if threshold is non-zero
     *      Used to prevent re-initialization attacks
     */
    modifier moduleIsNotInitialized() {
        require(!isInitialized(msg.sender), ModuleAlreadyInitialized(msg.sender));
        _;
    }

    /**
     * @dev Validates invariants after state changes to ensure configuration consistency
     *      Checks that owner count is within [MIN_OWNERS, MAX_OWNERS] bounds
     *      and that threshold is within [MIN_OWNERS, owner_count] bounds
     *      This prevents invalid states where threshold > owner count or no owners exist
     * @custom:security Critical for preventing locked accounts or threshold bypass
     */
    modifier ensureValidConfig() {
        _;
        _checkInvariants(msg.sender, MIN_OWNERS, MAX_OWNERS);
    }

    /* //////////////////////////////////////////////////////////////////////////
                                     INTERNAL
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Validates that owner count and threshold satisfy required invariants
     * @param account The account to check invariants for
     * @param minOwnersCount Minimum allowed number of owners
     * @param maxOwnersCount Maximum allowed number of owners
     * @custom:security This function enforces critical invariants:
     *                  1. Owner count must be within [minOwnersCount, maxOwnersCount]
     *                  2. Threshold must be >= minOwnersCount (at least minimum signatures
     * required)
     *                  3. Threshold must be <= ownersCount (can't require more signatures than
     * owners)
     *                  Without these checks, accounts could become locked (threshold > owners)
     *                  or vulnerable (threshold = 0)
     */
    function _checkInvariants(
        address account,
        uint256 minOwnersCount,
        uint256 maxOwnersCount
    )
        internal
        view
    {
        uint256 ownersCount = owners.length(account);
        uint256 threshold = thresholds[account];

        // Ensure owner count is within acceptable bounds
        require(
            minOwnersCount <= ownersCount && ownersCount <= maxOwnersCount,
            InvalidOwnersCount(ownersCount, minOwnersCount, maxOwnersCount)
        );

        // Ensure threshold is valid: must have enough owners to meet threshold
        // and threshold must be at least the minimum required
        require(
            minOwnersCount <= threshold && threshold <= ownersCount,
            InvalidThreshold(threshold, minOwnersCount, ownersCount)
        );
    }

    /**
     * @dev Updates the signature threshold for an account and emits event
     * @param account The account to update threshold for
     * @param _threshold The new threshold value
     * @custom:gas Single SSTORE operation for threshold update
     */
    function _setThreshold(address account, uint256 _threshold) internal {
        thresholds[account] = _threshold;
        emit ThresholdSet(account, _threshold);
    }

    /**
     * @dev Searches for an owner in the account's owner set and returns the packed element
     * @param account The account to search in
     * @param owner The owner address to find
     * @return found True if owner exists in the set
     * @return element The packed bytes32 element containing owner address and expiration
     * @custom:gas O(n) iteration over all owners - consider caching results if called multiple
     * times
     *             This is acceptable since MAX_OWNERS is capped at 32
     */
    function _findOwnerElement(
        address account,
        address owner
    )
        internal
        view
        returns (bool found, bytes32 element)
    {
        bytes32[] memory values = owners.values(account);

        // Linear search through all packed owner elements
        for (uint256 i = 0; i < values.length; i++) {
            address ownerAddr = values[i].unpackOwner();
            if (ownerAddr == owner) {
                return (true, values[i]);
            }
        }

        return (false, bytes32(0));
    }

    /**
     * @dev Checks if an owner is valid (exists and not expired) for an account
     * @param account The account to check ownership for
     * @param owner The owner address to validate
     * @return bool True if owner exists and is not expired, false otherwise
     * @custom:security This is the critical expiration check used during signature validation
     *                  An owner is valid only if:
     *                  1. They exist in the owner set
     *                  2. Current time <= expiration (type(uint48).max = permanent/never expires)
     *                  This ensures expired owners cannot sign transactions even if their
     *                  signatures are technically valid. Owner is expired AFTER the expiration
     * timestamp.
     */
    function _isOwnerValid(address account, address owner) internal view returns (bool) {
        (bool found, bytes32 element) = _findOwnerElement(account, owner);
        if (!found) return false;

        (, uint48 expiration) = element.unpackOwnerAndExpiration();

        // Owner is valid if current time is at or before expiration timestamp
        // At exactly expiration timestamp, owner is still valid
        // type(uint48).max represents permanent ownership (expires at end of representable time)
        return block.timestamp <= expiration;
    }

    /**
     * @dev Adds multiple owners to an account with their expiration timestamps
     * @param account The account to add owners to
     * @param newOwners Array of Owner structs containing addresses and expirations
     * @custom:gas Performs one SSTORE per new owner added. The EnumerableSet.add returns false
     *             if the element already exists, preventing duplicate owner events
     * @custom:security Validates that owner address is not zero and expiration is valid
     */
    function _addOwners(address account, Owner[] memory newOwners) internal {
        for (uint256 i = 0; i < newOwners.length; i++) {
            // Validate owner address is not zero
            if (newOwners[i].addr == address(0)) {
                revert ZeroAddressNotAllowed();
            }

            // Validate expiration is either permanent (type(uint48).max) or in the future
            // This prevents adding already-expired owners that would count toward total but not be
            // usable
            if (
                newOwners[i].expiration != type(uint48).max
                    && newOwners[i].expiration <= block.timestamp
            ) {
                revert ExpirationInPast(newOwners[i].expiration);
            }

            // Pack owner address and expiration into a single bytes32 for storage efficiency
            bytes32 element = newOwners[i].addr.toSetElement(newOwners[i].expiration);

            // Only emit event if owner was actually added (not already present)
            if (owners.add(account, element)) emit OwnerAdded(account, newOwners[i].addr);
        }
    }

    /**
     * @dev Removes multiple owners from an account
     * @param account The account to remove owners from
     * @param ownersToRemove Array of owner addresses to remove
     * @custom:gas Performs O(n) search for each owner to remove, then one SSTORE per removal
     *             The two-step process (find then remove) is necessary because owners are stored
     *             as packed bytes32 values, not directly as addresses
     */
    function _removeOwners(address account, address[] memory ownersToRemove) internal {
        for (uint256 i = 0; i < ownersToRemove.length; i++) {
            // Must find the packed element first since set stores bytes32, not addresses
            (bool found, bytes32 element) = _findOwnerElement(account, ownersToRemove[i]);

            // Only emit event if owner existed and was successfully removed
            if (found && owners.remove(account, element)) {
                emit OwnerRemoved(account, ownersToRemove[i]);
            }
        }
    }

    /**
     * @dev Internal function to update account configuration (threshold, add/remove owners)
     * @param newThreshold The new signature threshold to set
     * @param ownersToAdd Array of owners to add with expiration timestamps
     * @param ownersToRemove Array of owner addresses to remove
     * @custom:security The ensureValidConfig modifier ensures the final state is valid:
     *                  - Owners are removed first, then added, then threshold is set
     *                  - This order matters: removing owners might temporarily violate invariants,
     *                    but adding owners and setting threshold restores validity
     *                  - Invariants are checked AFTER all changes, preventing intermediate invalid
     * states
     */
    function _updateConfig(
        uint256 newThreshold,
        Owner[] memory ownersToAdd,
        address[] memory ownersToRemove
    )
        internal
        ensureValidConfig
        moduleIsInitialized
    {
        address account = msg.sender;

        // Execute changes in specific order: remove, add, then set threshold
        // This allows operations like replacing owners while adjusting threshold
        _removeOwners(account, ownersToRemove);
        _addOwners(account, ownersToAdd);
        _setThreshold(account, newThreshold);

        // ensureValidConfig modifier validates the final state after all changes
    }

    /* //////////////////////////////////////////////////////////////////////////
                                PUBLIC
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the configuration for the calling account
     * @dev This function allows atomic updates to threshold and owner set
     *      WARNING: This function is NOT idempotent - calling it multiple times with the
     *      same parameters may have different effects (e.g., if owners expire between calls)
     * @param newThreshold The new signature threshold (must satisfy: MIN_OWNERS <= threshold <=
     * owner_count)
     * @param ownersToAdd Array of owners to add with their expiration timestamps (type(uint48).max
     * = permanent/never expires)
     * @param ownersToRemove Array of owner addresses to remove from the account
     * @custom:security The ensureValidConfig modifier ensures the final configuration is valid
     *                  Callers should ensure they're not removing critical owners or setting
     *                  an unreachable threshold
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
     * @notice Updates the expiration time for an existing owner
     * @dev Useful for extending or reducing an owner's access period without removing and re-adding
     *      The owner must already exist in the set
     * @param owner The address of the existing owner to update
     * @param newExpiration The new expiration timestamp (type(uint48).max = permanent/never
     * expires)
     * @custom:gas This performs a remove + add operation (2 SSTOREs) rather than an in-place update
     *             because EnumerableSet doesn't support element modification
     * @custom:security Validates that new expiration is either permanent or in the future
     */
    function updateOwnerExpiration(address owner, uint48 newExpiration) public moduleIsInitialized {
        address account = msg.sender;
        (bool found, bytes32 oldElement) = _findOwnerElement(account, owner);

        require(found, OwnerNotFound(account, owner));

        // Validate new expiration is either permanent (type(uint48).max) or in the future
        // This prevents setting an expiration in the past which would immediately invalidate the
        // owner
        if (newExpiration != type(uint48).max && newExpiration <= block.timestamp) {
            revert ExpirationInPast(newExpiration);
        }

        // Must remove and re-add because EnumerableSet stores elements as unique bytes32 values
        // Changing expiration creates a different bytes32, so we can't modify in-place
        owners.remove(account, oldElement);
        bytes32 newElement = owner.toSetElement(newExpiration);
        owners.add(account, newElement);

        emit OwnerExpirationUpdated(account, owner, newExpiration);
    }

    /**
     * @notice Initializes the module for a smart account
     * @dev Called by the smart account during module installation
     *      Decodes initialization data to set up initial owners and threshold
     * @param data ABI-encoded tuple of (uint256 threshold, Owner[] owners)
     * @custom:security The moduleIsNotInitialized modifier prevents re-initialization
     *                  The ensureValidConfig modifier ensures valid initial configuration
     */
    function onInstall(bytes calldata data)
        external
        override
        moduleIsNotInitialized
        ensureValidConfig
    {
        (uint256 threshold, Owner[] memory newOwners) = abi.decode(data, (uint256, Owner[]));
        _onInstall(threshold, newOwners);
    }

    function _onInstall(uint256 threshold, Owner[] memory newOwners) internal virtual {
        address account = msg.sender;
        require(
            threshold <= newOwners.length, InvalidThreshold(threshold, MIN_OWNERS, newOwners.length)
        );

        // Set up initial configuration
        _addOwners(account, newOwners);
        _setThreshold(account, threshold);

        emit ModuleInitialized(account);
    }

    /**
     * @notice Uninstalls the module from a smart account
     * @dev Removes all owners and resets threshold to 0
     * @custom:security After uninstall, checkInvariants is called with (0,0) bounds to ensure
     *                  complete cleanup. The account will have 0 owners and 0 threshold.
     */
    function onUninstall(bytes calldata) external override {
        address account = msg.sender;

        // Extract all owner addresses from the packed storage elements
        Owner[] memory currentOwners = getOwners(account);
        address[] memory ownersToRemove = new address[](currentOwners.length);
        for (uint256 i = 0; i < currentOwners.length; i++) {
            ownersToRemove[i] = currentOwners[i].addr;
        }

        // Complete cleanup: remove all owners and reset threshold
        _removeOwners(account, ownersToRemove);
        _setThreshold(account, 0);

        // Verify complete removal (0 owners, 0 threshold)
        _checkInvariants(account, 0, 0);

        emit ModuleUninitialized(msg.sender);
    }

    /* //////////////////////////////////////////////////////////////////////////
                                VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if the module is initialized for a given smart account
     * @param smartAccount The account address to check
     * @return bool True if initialized (threshold > 0), false otherwise
     * @dev Initialization state is determined by non-zero threshold since threshold
     *      is set during onInstall and reset to 0 during onUninstall
     */
    function isInitialized(address smartAccount) public view returns (bool) {
        return thresholds[smartAccount] != 0;
    }

    /**
     * @notice Retrieves all owners for an account with their expiration timestamps
     * @param account The account to get owners for
     * @return ownersArray Array of Owner structs containing addresses and expiration times
     * @dev Returns ALL owners including expired ones. Callers should check expiration
     *      if they need only currently valid owners. This function unpacks the bytes32
     *      storage elements into human-readable Owner structs.
     * @custom:gas O(n) where n is number of owners. Loads all owner data from storage.
     */
    function getOwners(address account) public view returns (Owner[] memory ownersArray) {
        bytes32[] memory elements = owners.values(account);
        ownersArray = new Owner[](elements.length);

        // Unpack each bytes32 element into an Owner struct
        for (uint256 i = 0; i < elements.length; i++) {
            (address ownerAddr, uint48 expiration) = elements[i].unpackOwnerAndExpiration();
            ownersArray[i] = Owner(ownerAddr, expiration);
        }
    }

    /**
     * @notice Checks if an address is an owner of an account
     * @param account The account to check
     * @param owner The address to check for ownership
     * @return bool True if the address is an owner (regardless of expiration), false otherwise
     * @dev This only checks existence, NOT validity. An expired owner will still return true.
     *      For validity checking (including expiration), use _isOwnerValid internally or
     *      check getOwnerExpiration and compare with block.timestamp
     */
    function isOwner(address account, address owner) public view returns (bool) {
        (bool found,) = _findOwnerElement(account, owner);
        return found;
    }

    /**
     * @notice Returns the total number of owners for an account
     * @param account The account to get owner count for
     * @return uint256 The number of owners (including expired owners)
     * @dev This count includes expired owners since expiration doesn't remove them from storage
     */
    function getOwnersCount(address account) public view returns (uint256) {
        return owners.length(account);
    }

    /**
     * @notice Gets the expiration timestamp for a specific owner
     * @param account The account to check
     * @param owner The owner address to get expiration for
     * @return uint48 The expiration timestamp (0 if owner doesn't exist, type(uint48).max =
     * permanent/never expires)
     * @dev Returns 0 for non-existent owners. For existing owners, type(uint48).max means
     * permanent.
     *      Callers should use isOwner to check existence first if needed.
     */
    function getOwnerExpiration(address account, address owner) public view returns (uint48) {
        (bool found, bytes32 element) = _findOwnerElement(account, owner);
        if (!found) return 0;
        (, uint48 expiration) = element.unpackOwnerAndExpiration();
        return expiration;
    }

    /* //////////////////////////////////////////////////////////////////////////
                            VALIDATION FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Validates a user operation according to ERC-4337 specification
     * @dev This is the primary validation method for UserOperations in ERC-4337 Account Abstraction
     *      The function performs stateful validation using stored threshold and owners
     * @param userOp The packed user operation containing sender, nonce, calldata, and signature
     * @param userOpHash The hash of the user operation (excluding signature)
     * @return ValidationData ERC-4337 validation result (VALIDATION_SUCCESS or VALIDATION_FAILED)
     * @custom:security The userOpHash is wrapped with EIP-191 "\x19Ethereum Signed Message" prefix
     *                  before validation. This prevents signature reuse across different contexts.
     *                  Only signatures from valid (non-expired) owners count toward threshold.
     */
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    )
        external
        view
        override
        returns (ValidationData)
    {
        // Apply EIP-191 prefix to prevent cross-context signature reuse
        // This ensures UserOp signatures can't be replayed as EIP-712 signatures
        bool isValid = _validateSignatureWithConfig(
            userOp.sender, ECDSA.toEthSignedMessageHash(userOpHash), userOp.signature
        );

        // Return standardized ERC-4337 validation result
        if (isValid) {
            return VALIDATION_SUCCESS;
        }
        return VALIDATION_FAILED;
    }

    /**
     * @notice Validates an EIP-1271 signature with the sender context
     * @dev Routes through ERC-7739's nested EIP-712 / PersonalSign workflow to prevent
     *      cross-account signature replay when one EOA owns multiple smart accounts.
     *      The base contract takes care of:
     *      - Detection probe (returns SUPPORTS_ERC7739_V1 when called with empty sig + magic hash)
     *      - ERC-6492 wrapper unwrapping
     *      - Signature malleability check
     *      - Rebuilding the final hash via TypedDataSign or PersonalSign
     *      The actual signature verification then lands in
     * `_erc1271IsValidSignatureNowCalldata`
     *      which delegates back to our existing multisig + expiration validator.
     * @param sender The contract that called isValidSignature on the smart account
     * @param hash The hash of the data that was signed (typically an EIP-712 hash)
     * @param data The signature data to validate (may be ERC-6492 wrapped)
     * @return bytes4 EIP1271_SUCCESS (0x1626ba7e) if valid, EIP1271_FAILED (0xffffffff) otherwise
     */
    function isValidSignatureWithSender(
        address sender,
        bytes32 hash,
        bytes calldata data
    )
        external
        view
        override
        returns (bytes4)
    {
        return _erc1271IsValidSignatureWithSender(sender, hash, _erc1271UnwrapSignature(data));
    }

    /**
     * @dev ERC-7739 hook: validate a signature against the stored owner config.
     *      Called by the ERC7739Validator base after it has finished rewrapping `hash`
     *      into either the TypedDataSign or PersonalSign final digest. At this point
     *      `msg.sender` is the smart account whose config we look up, matching the
     *      semantics of the original isValidSignatureWithSender path.
     * @param hash The final hash (already nested-EIP-712 wrapped by the base contract)
     * @param signature The raw signature(s) to verify (no appended ERC-7739 metadata —
     *                  the base contract has already truncated it)
     * @return bool True iff threshold is met by valid, non-expired owners
     */
    function _erc1271IsValidSignatureNowCalldata(
        bytes32 hash,
        bytes calldata signature
    )
        internal
        view
        override
        returns (bool)
    {
        return _validateSignatureWithConfig(msg.sender, hash, signature);
    }

    /**
     * @notice Validates a signature using configuration passed as calldata (stateless mode)
     * @dev This is a stateless validation function that doesn't rely on stored configuration
     *      Useful for validating signatures before module installation or for off-chain
     * verification
     *      WARNING: This function does NOT check owner expiration - all provided owners are treated
     * as valid
     * @param hash The hash of the data that was signed
     * @param signature The concatenated signatures from the owners
     * @param data ABI-encoded tuple of (uint256 threshold, address[] owners)
     * @return bool True if threshold is met by valid owner signatures, false otherwise
     * @custom:security This function has important security properties:
     *                  1. Owners array MUST be sorted and unique (prevents owner reuse)
     *                  2. Recovered signers are sorted and uniquified (prevents signature reuse)
     *                  3. Threshold must be > 0 (prevents trivial bypass)
     *                  4. Uses binary search for efficient owner lookup
     *                  5. Does NOT check expiration (by design, as expiration requires stored
     * config)
     */
    function validateSignatureWithData(
        bytes32 hash,
        bytes calldata signature,
        bytes calldata data
    )
        external
        view
        returns (bool)
    {
        // Decode the stateless configuration from calldata
        (uint256 _threshold, address[] memory _owners) = abi.decode(data, (uint256, address[]));

        // Validate that owners array is sorted and has no duplicates
        // This is required for binary search and prevents an owner from being counted multiple
        // times
        if (!_owners.isSortedAndUniquified()) {
            return false;
        }

        // Threshold must be non-zero to prevent trivial validation bypass
        if (_threshold == 0) {
            return false;
        }

        // Recover signer addresses from the provided signatures
        // CheckSignatures library expects exactly _threshold signatures
        address[] memory signers = CheckSignatures.recoverNSignatures(hash, signature, _threshold);

        // Sort and uniquify signers to prevent signature reuse attacks
        // Without this, the same signature could be submitted multiple times to meet threshold
        signers.sort();
        signers.uniquifySorted();

        // Count how many recovered signers are in the provided owners list
        uint256 validSigners;
        uint256 signersLength = signers.length;
        for (uint256 i = 0; i < signersLength; i++) {
            // Binary search in sorted owners array (O(log n) instead of O(n))
            (bool found,) = _owners.searchSorted(signers[i]);
            if (found) {
                validSigners++;
            }
        }

        // Validation succeeds if we have enough valid signatures to meet threshold
        if (validSigners >= _threshold) {
            return true;
        }

        return false;
    }

    /**
     * @dev Internal function for stateful signature validation using stored configuration
     * @param account The account to validate signatures for
     * @param hash The hash that was signed
     * @param data The signature data
     * @return bool True if threshold is met by valid, non-expired owners, false otherwise
     * @custom:security This is the core validation logic that:
     *                  1. Checks threshold is initialized (non-zero)
     *                  2. Recovers signers from signatures using CheckSignatures library
     *                  3. Sorts and uniquifies signers to prevent signature reuse
     *                  4. Validates each signer is an owner AND not expired via _isOwnerValid
     *                  5. Counts valid signers and checks against threshold
     *                  The key difference from validateSignatureWithData is the expiration check
     *                  in step 4, which ensures expired owners cannot authorize transactions
     * @custom:gas O(n*m) where n=threshold and m=total owners (for expiration lookup)
     *             Could be optimized by caching owner set in memory, but threshold is typically
     * small
     */
    function _validateSignatureWithConfig(
        address account,
        bytes32 hash,
        bytes calldata data
    )
        internal
        view
        returns (bool)
    {
        // Load threshold from storage and verify module is initialized
        uint256 _threshold = thresholds[account];
        if (_threshold == 0) {
            return false;
        }

        // Recover the addresses that signed this hash
        // CheckSignatures expects exactly _threshold concatenated signatures
        address[] memory signers = CheckSignatures.recoverNSignatures(hash, data, _threshold);

        // Sort and uniquify signers to prevent the same signature from being counted multiple times
        // This prevents an attacker from submitting duplicate signatures to meet threshold
        signers.sort();
        signers.uniquifySorted();

        // Count how many signers are valid owners (exist and not expired)
        uint256 validSigners;
        uint256 signersLength = signers.length;
        for (uint256 i = 0; i < signersLength; i++) {
            // _isOwnerValid checks both existence AND expiration
            // This is the critical security check that enforces time-based access revocation
            if (_isOwnerValid(account, signers[i])) {
                validSigners++;
            }
        }

        // Validation succeeds only if we have enough valid signatures
        if (validSigners >= _threshold) {
            return true;
        }

        return false;
    }

    /* //////////////////////////////////////////////////////////////////////////
                                     METADATA
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if this module supports a given ERC-7579 module type
     * @param typeID The module type identifier to check
     * @return bool True if the module type is supported, false otherwise
     * @dev This module supports both TYPE_VALIDATOR and TYPE_STATELESS_VALIDATOR:
     *      - TYPE_VALIDATOR: Standard stateful validation using stored configuration
     *      - TYPE_STATELESS_VALIDATOR: Validation with configuration passed in calldata
     *      The dual-mode support allows this module to validate signatures even before
     *      it's installed on an account (useful for signature verification workflows)
     */
    function isModuleType(uint256 typeID) external pure override returns (bool) {
        return typeID == TYPE_VALIDATOR || typeID == TYPE_STATELESS_VALIDATOR;
    }

    /**
     * @notice Returns the human-readable name of this module
     * @return string The module name
     * @dev Note: This returns "OwnableValidator" for compatibility but this is actually
     *      the OwnableValidator with expiration support
     */
    function name() external pure virtual returns (string memory) {
        return "OwnableValidator";
    }

    /**
     * @notice Returns the version of this module
     * @return string The semantic version string
     */
    function version() external pure virtual returns (string memory) {
        return "2.0.0";
    }
}

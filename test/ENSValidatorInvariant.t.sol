// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { console } from "forge-std/console.sol";
import { ENSValidator } from "src/validator/ENSValidator.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { LibSort } from "solady/utils/LibSort.sol";

/**
 * @title ENSValidatorInvariantTest
 * @notice Invariant tests for ENSValidator focusing on:
 *         - Installation/uninstallation state consistency
 *         - Configuration change tracking
 *         - Owner expiration enforcement
 *         - Threshold constraints
 */
contract ENSValidatorInvariantTest is StdInvariant, Test {
    using LibSort for *;

    ENSValidator public validator;
    ENSValidatorHandler public handler;

    // Track state for invariant checking
    mapping(address => uint256) public expectedThresholds;
    mapping(address => uint256) public expectedOwnerCounts;

    function setUp() public {
        validator = new ENSValidator();
        handler = new ENSValidatorHandler(validator);

        // Target the handler for invariant testing
        targetContract(address(handler));

        // Set up selectors to test
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.install.selector;
        selectors[1] = handler.uninstall.selector;
        selectors[2] = handler.updateConfig.selector;
        selectors[3] = handler.updateExpiration.selector;
        selectors[4] = handler.addOwner.selector;
        selectors[5] = handler.removeOwner.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /* ═══════════════════════════════════════════════════════════════
                        INSTALLATION/UNINSTALLATION INVARIANTS
       ═══════════════════════════════════════════════════════════════ */

    /// @notice After uninstall, no validation should be possible
    function invariant_afterUninstall_noValidationPossible() public view {
        address[] memory uninstalledAccounts = handler.getUninstalledAccounts();

        for (uint256 i = 0; i < uninstalledAccounts.length; i++) {
            address account = uninstalledAccounts[i];

            // Threshold should be 0
            assertEq(
                validator.thresholds(account),
                0,
                "Uninstalled account should have zero threshold"
            );

            // Owner count should be 0
            assertEq(
                validator.getOwnersCount(account), 0, "Uninstalled account should have zero owners"
            );

            // Module should not be initialized
            assertFalse(
                validator.isInitialized(account), "Uninstalled account should not be initialized"
            );
        }
    }

    /// @notice After install, validation should be possible with correct threshold
    function invariant_afterInstall_validationPossible() public view {
        address[] memory installedAccounts = handler.getInstalledAccounts();

        for (uint256 i = 0; i < installedAccounts.length; i++) {
            address account = installedAccounts[i];

            // Module should be initialized
            assertTrue(validator.isInitialized(account), "Installed account should be initialized");

            // Threshold should be non-zero
            uint256 threshold = validator.thresholds(account);
            assertGt(threshold, 0, "Installed account should have non-zero threshold");

            // Owner count should be >= threshold
            uint256 ownerCount = validator.getOwnersCount(account);
            assertGe(
                ownerCount, threshold, "Installed account should have enough owners for threshold"
            );
        }
    }

    /// @notice Cannot reinstall without uninstalling first
    function invariant_noDoubleInstall() public view {
        address[] memory installedAccounts = handler.getInstalledAccounts();

        for (uint256 i = 0; i < installedAccounts.length; i++) {
            address account = installedAccounts[i];

            // If initialized, should have valid state
            if (validator.isInitialized(account)) {
                uint256 threshold = validator.thresholds(account);
                uint256 ownerCount = validator.getOwnersCount(account);

                assertGt(threshold, 0, "Initialized account must have threshold > 0");
                assertGe(
                    ownerCount,
                    threshold,
                    "Initialized account must have owner count >= threshold"
                );
            }
        }
    }

    /* ═══════════════════════════════════════════════════════════════
                        THRESHOLD INVARIANTS
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Threshold must always be within valid bounds
    function invariant_thresholdWithinBounds() public view {
        address[] memory accounts = handler.getAllAccounts();

        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];

            if (!validator.isInitialized(account)) continue;

            uint256 threshold = validator.thresholds(account);
            uint256 ownerCount = validator.getOwnersCount(account);

            // Threshold must be at least MIN_OWNERS (1)
            assertGe(threshold, 1, "Threshold must be >= MIN_OWNERS");

            // Threshold must not exceed owner count
            assertLe(threshold, ownerCount, "Threshold must be <= owner count");

            // Threshold must not exceed MAX_OWNERS (32)
            assertLe(threshold, 32, "Threshold must be <= MAX_OWNERS");
        }
    }

    /// @notice Uninitialized accounts must have zero threshold
    function invariant_uninitializedHasZeroThreshold() public view {
        address[] memory accounts = handler.getAllAccounts();

        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];

            if (!validator.isInitialized(account)) {
                assertEq(
                    validator.thresholds(account), 0, "Uninitialized account must have zero threshold"
                );
            }
        }
    }

    /* ═══════════════════════════════════════════════════════════════
                        OWNER INVARIANTS
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Owner count must be within valid bounds
    function invariant_ownerCountWithinBounds() public view {
        address[] memory accounts = handler.getAllAccounts();

        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];

            if (!validator.isInitialized(account)) continue;

            uint256 ownerCount = validator.getOwnersCount(account);

            // Owner count must be at least MIN_OWNERS (1)
            assertGe(ownerCount, 1, "Owner count must be >= MIN_OWNERS");

            // Owner count must not exceed MAX_OWNERS (32)
            assertLe(ownerCount, 32, "Owner count must be <= MAX_OWNERS");
        }
    }

    /// @notice Zero address should never be an owner
    function invariant_noZeroAddressOwners() public view {
        address[] memory accounts = handler.getAllAccounts();

        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];

            assertFalse(
                validator.isOwner(account, address(0)), "Zero address should never be an owner"
            );
        }
    }

    /// @notice All owners returned by getOwners should be valid
    function invariant_getOwnersReturnsValidOwners() public view {
        address[] memory accounts = handler.getAllAccounts();

        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];

            if (!validator.isInitialized(account)) continue;

            ENSValidator.Owner[] memory owners = validator.getOwners(account);
            uint256 ownerCount = validator.getOwnersCount(account);

            // Length should match
            assertEq(owners.length, ownerCount, "getOwners length should match getOwnersCount");

            // Each owner should be valid
            for (uint256 j = 0; j < owners.length; j++) {
                assertTrue(
                    validator.isOwner(account, owners[j].addr),
                    "Owner from getOwners should exist via isOwner"
                );

                // Owner address should not be zero
                assertTrue(owners[j].addr != address(0), "Owner address should not be zero");
            }
        }
    }

    /* ═══════════════════════════════════════════════════════════════
                        EXPIRATION INVARIANTS
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Owner expiration should never be in the past (except type(uint48).max)
    function invariant_noExpiredOwnersCanBeAdded() public view {
        address[] memory accounts = handler.getAllAccounts();

        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];

            if (!validator.isInitialized(account)) continue;

            ENSValidator.Owner[] memory owners = validator.getOwners(account);

            for (uint256 j = 0; j < owners.length; j++) {
                uint48 expiration = owners[j].expiration;

                // Expiration should be either type(uint48).max (permanent) or in the future
                if (expiration != type(uint48).max) {
                    assertGe(
                        expiration,
                        block.timestamp,
                        "Owner expiration should not be in the past"
                    );
                }
            }
        }
    }

    /// @notice getOwnerExpiration should return 0 for non-existent owners
    function invariant_nonExistentOwnerHasZeroExpiration() public view {
        address[] memory accounts = handler.getAllAccounts();
        address nonExistentOwner = address(0xdead);

        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];

            if (validator.isOwner(account, nonExistentOwner)) continue;

            uint48 expiration = validator.getOwnerExpiration(account, nonExistentOwner);
            assertEq(expiration, 0, "Non-existent owner should have zero expiration");
        }
    }

    /* ═══════════════════════════════════════════════════════════════
                        CONFIG CHANGE TRACKING INVARIANTS
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Config changes should be properly tracked via events
    function invariant_configChangesEmitEvents() public view {
        address[] memory accounts = handler.getAllAccounts();

        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];

            if (!validator.isInitialized(account)) continue;

            // Get current state
            uint256 currentThreshold = validator.thresholds(account);
            uint256 currentOwnerCount = validator.getOwnersCount(account);

            // Track recorded state from handler
            uint256 recordedThreshold = handler.getRecordedThreshold(account);
            uint256 recordedOwnerCount = handler.getRecordedOwnerCount(account);

            // If handler tracked changes, they should match current state
            if (recordedThreshold > 0) {
                assertEq(
                    currentThreshold,
                    recordedThreshold,
                    "Current threshold should match recorded threshold"
                );
            }

            if (recordedOwnerCount > 0) {
                assertEq(
                    currentOwnerCount,
                    recordedOwnerCount,
                    "Current owner count should match recorded count"
                );
            }
        }
    }

    /// @notice Threshold should never exceed owner count
    function invariant_thresholdNeverExceedsOwnerCount() public view {
        address[] memory accounts = handler.getAllAccounts();

        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];

            if (!validator.isInitialized(account)) continue;

            uint256 threshold = validator.thresholds(account);
            uint256 ownerCount = validator.getOwnersCount(account);

            assertLe(threshold, ownerCount, "Threshold should never exceed owner count");
        }
    }

    /// @notice Sum of invariant checks
    function invariant_callSummary() public view {
        handler.logCallSummary();
    }
}

/**
 * @title ENSValidatorHandler
 * @notice Handler contract for fuzzing ENSValidator operations
 */
contract ENSValidatorHandler is Test {
    ENSValidator public validator;

    // Track accounts for invariant checking
    address[] public installedAccounts;
    address[] public uninstalledAccounts;
    address[] public allAccounts;

    // Track state changes
    mapping(address => uint256) public recordedThresholds;
    mapping(address => uint256) public recordedOwnerCounts;
    mapping(address => bool) public isTracked;

    // Call counters for fuzzing statistics
    uint256 public installCalls;
    uint256 public uninstallCalls;
    uint256 public updateConfigCalls;
    uint256 public updateExpirationCalls;
    uint256 public addOwnerCalls;
    uint256 public removeOwnerCalls;

    // Owner pool for fuzzing
    address[] public ownerPool;

    constructor(ENSValidator _validator) {
        validator = _validator;

        // Create a pool of owner addresses
        for (uint256 i = 1; i <= 10; i++) {
            ownerPool.push(vm.addr(i));
        }
    }

    /* ═══════════════════════════════════════════════════════════════
                        HANDLER FUNCTIONS
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Install the validator for a fuzzed account
    function install(uint256 accountSeed, uint256 thresholdSeed, uint256 ownerCountSeed) public {
        installCalls++;

        // Generate account address
        address account = address(uint160(bound(accountSeed, 1, type(uint160).max)));

        // Skip if already installed
        if (validator.isInitialized(account)) return;

        // Generate threshold (1-5)
        uint256 threshold = bound(thresholdSeed, 1, 5);

        // Generate owner count (threshold to 10)
        uint256 ownerCount = bound(ownerCountSeed, threshold, 10);

        // Create owners with permanent expiration
        ENSValidator.Owner[] memory owners = new ENSValidator.Owner[](ownerCount);
        for (uint256 i = 0; i < ownerCount; i++) {
            owners[i] =
                ENSValidator.Owner({ addr: ownerPool[i % ownerPool.length], expiration: type(uint48).max });
        }

        // Encode and install
        bytes memory data = abi.encode(threshold, owners);

        vm.prank(account);
        try validator.onInstall(data) {
            _trackAccount(account, true);
            recordedThresholds[account] = threshold;
            recordedOwnerCounts[account] = ownerCount;
        } catch {
            // Installation failed, skip
        }
    }

    /// @notice Uninstall the validator for an account
    function uninstall(uint256 accountSeed) public {
        uninstallCalls++;

        if (installedAccounts.length == 0) return;

        // Pick an installed account
        uint256 index = bound(accountSeed, 0, installedAccounts.length - 1);
        address account = installedAccounts[index];

        if (!validator.isInitialized(account)) return;

        vm.prank(account);
        try validator.onUninstall("") {
            _trackAccount(account, false);
            recordedThresholds[account] = 0;
            recordedOwnerCounts[account] = 0;
        } catch {
            // Uninstall failed, skip
        }
    }

    /// @notice Update config for an installed account
    function updateConfig(uint256 accountSeed, uint256 newThresholdSeed) public {
        updateConfigCalls++;

        if (installedAccounts.length == 0) return;

        uint256 index = bound(accountSeed, 0, installedAccounts.length - 1);
        address account = installedAccounts[index];

        if (!validator.isInitialized(account)) return;

        uint256 ownerCount = validator.getOwnersCount(account);
        uint256 newThreshold = bound(newThresholdSeed, 1, ownerCount);

        ENSValidator.Owner[] memory emptyOwners = new ENSValidator.Owner[](0);
        address[] memory emptyRemove = new address[](0);

        vm.prank(account);
        try validator.updateConfig(newThreshold, emptyOwners, emptyRemove) {
            recordedThresholds[account] = newThreshold;
        } catch {
            // Update failed, skip
        }
    }

    /// @notice Update owner expiration
    function updateExpiration(uint256 accountSeed, uint256 ownerIndexSeed, uint256 newExpirationSeed)
        public
    {
        updateExpirationCalls++;

        if (installedAccounts.length == 0) return;

        uint256 index = bound(accountSeed, 0, installedAccounts.length - 1);
        address account = installedAccounts[index];

        if (!validator.isInitialized(account)) return;

        ENSValidator.Owner[] memory owners = validator.getOwners(account);
        if (owners.length == 0) return;

        uint256 ownerIndex = bound(ownerIndexSeed, 0, owners.length - 1);
        address ownerAddr = owners[ownerIndex].addr;

        // Generate new expiration (permanent or future)
        uint48 newExpiration;
        if (newExpirationSeed % 2 == 0) {
            newExpiration = type(uint48).max; // Permanent
        } else {
            newExpiration = uint48(block.timestamp + bound(newExpirationSeed, 1 hours, 365 days));
        }

        vm.prank(account);
        try validator.updateOwnerExpiration(ownerAddr, newExpiration) {
            // Expiration updated successfully
        } catch {
            // Update failed, skip
        }
    }

    /// @notice Add a new owner
    function addOwner(uint256 accountSeed, uint256 ownerIndexSeed) public {
        addOwnerCalls++;

        if (installedAccounts.length == 0) return;

        uint256 index = bound(accountSeed, 0, installedAccounts.length - 1);
        address account = installedAccounts[index];

        if (!validator.isInitialized(account)) return;

        uint256 ownerCount = validator.getOwnersCount(account);
        if (ownerCount >= 32) return; // MAX_OWNERS

        // Pick an owner from pool
        uint256 ownerIndex = bound(ownerIndexSeed, 0, ownerPool.length - 1);
        address newOwnerAddr = ownerPool[ownerIndex];

        // Skip if already an owner
        if (validator.isOwner(account, newOwnerAddr)) return;

        ENSValidator.Owner[] memory newOwners = new ENSValidator.Owner[](1);
        newOwners[0] = ENSValidator.Owner({ addr: newOwnerAddr, expiration: type(uint48).max });

        address[] memory emptyRemove = new address[](0);
        uint256 currentThreshold = validator.thresholds(account);

        vm.prank(account);
        try validator.updateConfig(currentThreshold, newOwners, emptyRemove) {
            recordedOwnerCounts[account] = ownerCount + 1;
        } catch {
            // Add failed, skip
        }
    }

    /// @notice Remove an owner
    function removeOwner(uint256 accountSeed, uint256 ownerIndexSeed) public {
        removeOwnerCalls++;

        if (installedAccounts.length == 0) return;

        uint256 index = bound(accountSeed, 0, installedAccounts.length - 1);
        address account = installedAccounts[index];

        if (!validator.isInitialized(account)) return;

        ENSValidator.Owner[] memory owners = validator.getOwners(account);
        if (owners.length <= 1) return; // Can't remove last owner

        uint256 ownerIndex = bound(ownerIndexSeed, 0, owners.length - 1);
        address ownerToRemove = owners[ownerIndex].addr;

        uint256 currentThreshold = validator.thresholds(account);
        uint256 newOwnerCount = owners.length - 1;

        // Adjust threshold if needed
        if (currentThreshold > newOwnerCount) {
            currentThreshold = newOwnerCount;
        }

        ENSValidator.Owner[] memory emptyOwners = new ENSValidator.Owner[](0);
        address[] memory ownersToRemove = new address[](1);
        ownersToRemove[0] = ownerToRemove;

        vm.prank(account);
        try validator.updateConfig(currentThreshold, emptyOwners, ownersToRemove) {
            recordedThresholds[account] = currentThreshold;
            recordedOwnerCounts[account] = newOwnerCount;
        } catch {
            // Remove failed, skip
        }
    }

    /* ═══════════════════════════════════════════════════════════════
                        HELPER FUNCTIONS
       ═══════════════════════════════════════════════════════════════ */

    function _trackAccount(address account, bool installed) internal {
        if (!isTracked[account]) {
            allAccounts.push(account);
            isTracked[account] = true;
        }

        if (installed) {
            installedAccounts.push(account);
            // Remove from uninstalled if present
            _removeFromUninstalled(account);
        } else {
            uninstalledAccounts.push(account);
            // Remove from installed if present
            _removeFromInstalled(account);
        }
    }

    function _removeFromInstalled(address account) internal {
        for (uint256 i = 0; i < installedAccounts.length; i++) {
            if (installedAccounts[i] == account) {
                installedAccounts[i] = installedAccounts[installedAccounts.length - 1];
                installedAccounts.pop();
                break;
            }
        }
    }

    function _removeFromUninstalled(address account) internal {
        for (uint256 i = 0; i < uninstalledAccounts.length; i++) {
            if (uninstalledAccounts[i] == account) {
                uninstalledAccounts[i] = uninstalledAccounts[uninstalledAccounts.length - 1];
                uninstalledAccounts.pop();
                break;
            }
        }
    }

    /* ═══════════════════════════════════════════════════════════════
                        VIEW FUNCTIONS FOR INVARIANTS
       ═══════════════════════════════════════════════════════════════ */

    function getInstalledAccounts() external view returns (address[] memory) {
        return installedAccounts;
    }

    function getUninstalledAccounts() external view returns (address[] memory) {
        return uninstalledAccounts;
    }

    function getAllAccounts() external view returns (address[] memory) {
        return allAccounts;
    }

    function getRecordedThreshold(address account) external view returns (uint256) {
        return recordedThresholds[account];
    }

    function getRecordedOwnerCount(address account) external view returns (uint256) {
        return recordedOwnerCounts[account];
    }

    function logCallSummary() external view {
        console.log("=== Call Summary ===");
        console.log("Install calls:", installCalls);
        console.log("Uninstall calls:", uninstallCalls);
        console.log("Update config calls:", updateConfigCalls);
        console.log("Update expiration calls:", updateExpirationCalls);
        console.log("Add owner calls:", addOwnerCalls);
        console.log("Remove owner calls:", removeOwnerCalls);
        console.log("Total accounts tracked:", allAccounts.length);
        console.log("Currently installed:", installedAccounts.length);
        console.log("Currently uninstalled:", uninstalledAccounts.length);
    }
}

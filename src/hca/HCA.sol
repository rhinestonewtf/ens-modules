// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IValidator } from "nexus/interfaces/modules/IValidator.sol";
import { Initializable } from "nexus/lib/Initializable.sol";
import { Nexus } from "nexus/Nexus.sol";

import { IHCAFactory } from "@ensdomains/contracts-v2/src/hca/interfaces/IHCAFactory.sol";
import { IHCARevertNFTSelectors } from "./interfaces/IHCARevertNFTSelectors.sol";

/// @title HCA - Hardware-Controlled Account
/// @notice A Nexus-based smart account restricted to a single immutable validator and
/// factory-approved upgrades. Modules cannot be uninstalled once configured, enforcing a
/// locked-down account model
///         suitable for hardware-backed signers.
contract HCA is Nexus {
    /// @notice The factory that deployed this account, used to authorize upgrades.
    IHCAFactory private immutable _HCA_FACTORY;

    /// @notice Thrown when the factory address provided to the constructor is zero.
    /// @dev Error selector: `0x841d6202`
    error HCAFactoryCannotBeZero();

    /// @notice Thrown when a function restricted to the HCA factory is called by another address.
    /// @dev Error selector: `0x9a8c7026`
    error CallerNotHCAFactory();

    /// @notice Thrown when attempting to uninstall any module type (validator, executor, fallback
    /// handler, or hook). @dev Error selector: `0xca962ccf`
    error NoModuleChangeAllowed();

    /// @notice Thrown when an upgrade targets an implementation not approved by the factory.
    /// @param impl The rejected implementation address.
    /// @dev Error selector: `0x36e7c82f`
    error InvalidHCAUpgrade(address impl);

    // @notice The HCA is not allowed to have any NFTs.
    /// @dev Error selector: `0x6e29a697`
    error NoNFTAllowed();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the HCA with its factory, entry point, default validator, and default
    /// executor. @param hcaFactory_ The factory that manages this account's lifecycle and approved
    /// implementations.
    /// @param entryPoint_ The ERC-4337 entry point contract.
    /// @param defaultValidator_ The K1 validator used as the sole signer for this account.
    /// @param intentExecutor_ The intent executor set as the default executor.
    /// @param validatorInitData_ Init data for the default validator (blocks impl from direct use).
    constructor(
        IHCAFactory hcaFactory_,
        address entryPoint_,
        address defaultValidator_,
        address intentExecutor_,
        bytes memory validatorInitData_
    )
        Nexus(entryPoint_, defaultValidator_, intentExecutor_, validatorInitData_, "")
    {
        if (address(hcaFactory_) == address(0)) revert HCAFactoryCannotBeZero();
        _HCA_FACTORY = hcaFactory_;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the smart account with the specified initialization data.
    /// @param initData The initialization data for the default validator
    function initializeAccount(bytes calldata initData) external payable virtual override {
        // Nexus Proxy tstores this value to in its constructor.
        Initializable.requireInitializable();
        IValidator(_DEFAULT_VALIDATOR).onInstall(initData);
        IValidator(_DEFAULT_EXECUTOR).onInstall("");
    }

    /// @notice Blocks installation of any module. HCA accounts are locked to their initial
    /// configuration.
    function installModule(uint256, address, bytes calldata) external payable virtual override {
        revert NoModuleChangeAllowed();
    }

    /// @notice Blocks uninstallation of any module. HCA accounts are locked to their initial
    /// configuration.
    function uninstallModule(uint256, address, bytes calldata) external payable virtual override {
        revert NoModuleChangeAllowed();
    }

    /// @notice Returns the account implementation ID.
    function accountId() external pure override returns (string memory) {
        return "ens-hca.1.0.0";
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Guards UUPS upgrades so only the factory's current implementation is accepted.
    /// @dev Only callable via the entry point or the account itself (e.g. through a UserOp,
    /// Intent). Ensures the account can only be upgraded to the latest implementation registered on
    /// the HCA factory, preventing upgrades to arbitrary or malicious contracts.
    /// @param newImplementation The proposed new implementation address.
    function _authorizeUpgrade(address newImplementation)
        internal
        virtual
        override
        onlyEntryPointOrSelf
    {
        require(
            newImplementation == _HCA_FACTORY.getImplementation(),
            InvalidHCAUpgrade(newImplementation)
        );
        super._authorizeUpgrade(newImplementation);
    }

    /// @notice Intercepts fallback calls to reject incoming NFT transfers (ERC-721 and ERC-1155).
    /// @dev Reverts with `NoNFTAllowed()` for `onERC721Received`, `onERC1155Received`, and
    ///      `onERC1155BatchReceived` selectors. All other calls are forwarded to the parent
    /// fallback. @param callData The raw calldata of the incoming call.
    function _fallback(bytes calldata callData) internal override {
        bytes4 selector = bytes4(callData[0:4]);
        if (selector == IHCARevertNFTSelectors.onERC721Received.selector) revert NoNFTAllowed();
        if (selector == IHCARevertNFTSelectors.onERC1155Received.selector) revert NoNFTAllowed();
        if (selector == IHCARevertNFTSelectors.onERC1155BatchReceived.selector) {
            revert NoNFTAllowed();
        }
        super._fallback(callData);
    }
}

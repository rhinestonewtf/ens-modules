// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";

import { HCA } from "src/hca/HCA.sol";
import { HCAModule } from "src/hca-module/HCAModule.sol";
import { OwnableValidator } from "src/hca-module/base/OwnableValidator.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

import { HCAFactory } from "@ensdomains/contracts-v2/src/hca/HCAFactory.sol";
import { IHCAFactory } from "@ensdomains/contracts-v2/src/hca/interfaces/IHCAFactory.sol";
import {
    IHCAInitDataParser
} from "@ensdomains/contracts-v2/src/hca/interfaces/IHCAInitDataParser.sol";

import { ExecutionMode, ModeLib } from "nexus/lib/ModeLib.sol";
import { ExecLib } from "nexus/lib/ExecLib.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

// ─── Inline mock NFTs
// ────────────────────────────────────────────────────────

contract MockNFT is ERC721 {
    uint256 private _nextId;

    constructor() ERC721("MockNFT", "MNFT") { }

    function mint(address to) external returns (uint256 id) {
        id = _nextId++;
        _mint(to, id);
    }
}

contract MockMultiToken is ERC1155 {
    constructor() ERC1155("") { }

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function mintBatch(address to, uint256[] memory ids, uint256[] memory amounts) external {
        _mintBatch(to, ids, amounts, "");
    }
}

contract MockExecutor {
    function isModuleType(uint256 typeID) external pure returns (bool) {
        return typeID == 2; // MODULE_TYPE_EXECUTOR
    }

    function onInstall(bytes calldata) external { }

    function onUninstall(bytes calldata) external { }
}

// ─── Integration tests
// ──────────────────────────────────────────────────────

contract HCAIntegrationTest is Test, IERC721Receiver, IERC1155Receiver {
    HCAModule internal hcaModule;
    HCAFactory internal factory;
    HCA internal hcaImpl;
    address payable internal hcaAccount;

    MockNFT internal nft;
    MockMultiToken internal multiToken;
    MockERC20 internal erc20;
    MockExecutor internal executor;

    address internal entryPoint = makeAddr("entryPoint");
    address internal factoryOwner = makeAddr("factoryOwner");
    address internal owner1;
    uint256 internal owner1Key;
    address internal owner2;
    uint256 internal owner2Key;
    address internal owner3;
    uint256 internal owner3Key;
    address internal random = makeAddr("random");

    function setUp() public {
        (owner1, owner1Key) = makeAddrAndKey("owner1");
        (owner2, owner2Key) = makeAddrAndKey("owner2");
        (owner3, owner3Key) = makeAddrAndKey("owner3");

        // 1. Deploy HCAModule (validator + init data parser) and mock executor
        hcaModule = new HCAModule();
        executor = new MockExecutor();

        // 2. Deploy factory with zero implementation initially
        factory = new HCAFactory(address(0), IHCAInitDataParser(address(hcaModule)), factoryOwner);

        // 3. Build template init data (blocks implementation from being used directly)
        OwnableValidator.Owner[] memory templateOwners = new OwnableValidator.Owner[](1);
        templateOwners[0] =
            OwnableValidator.Owner({ addr: address(1), expiration: type(uint48).max });
        bytes memory initDataTemplate = abi.encode(uint256(1), templateOwners);

        // 4. Deploy HCA implementation
        hcaImpl = new HCA(
            IHCAFactory(address(factory)),
            entryPoint,
            address(hcaModule),
            address(executor),
            initDataTemplate
        );

        // 5. Set implementation on factory
        vm.prank(factoryOwner);
        factory.setImplementation(address(hcaImpl), IHCAInitDataParser(address(hcaModule)));

        // 6. Create account via factory (1 permanent owner, threshold 1)
        OwnableValidator.Owner[] memory accountOwners = new OwnableValidator.Owner[](1);
        accountOwners[0] = OwnableValidator.Owner({ addr: owner1, expiration: type(uint48).max });
        bytes memory initData = abi.encode(uint256(1), accountOwners);

        hcaAccount = factory.createAccount(initData);

        // 7. Deploy mock tokens
        nft = new MockNFT();
        multiToken = new MockMultiToken();
        erc20 = new MockERC20("Mock", "MCK", 18);
    }

    // ──────────────────────────────────────────────────────────────────────
    // ERC-721/1155 receiver (so this test contract can hold NFTs)
    // ──────────────────────────────────────────────────────────────────────

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    )
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    )
        external
        pure
        override
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    )
        external
        pure
        override
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC721Receiver).interfaceId
            || interfaceId == type(IERC1155Receiver).interfaceId;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Account Creation via Factory
    // ══════════════════════════════════════════════════════════════════════

    function test_createAccount_deterministicAddress() public view {
        address predicted = factory.computeAccountAddress(owner1);
        assertEq(hcaAccount, predicted);
    }

    function test_createAccount_ownerMapping() public view {
        assertEq(factory.getAccountOwner(hcaAccount), owner1);
    }

    function test_createAccount_idempotent() public {
        OwnableValidator.Owner[] memory owners = new OwnableValidator.Owner[](1);
        owners[0] = OwnableValidator.Owner({ addr: owner1, expiration: type(uint48).max });
        bytes memory initData = abi.encode(uint256(1), owners);

        address payable second = factory.createAccount(initData);
        assertEq(second, hcaAccount);
    }

    function test_createAccount_initializedAfterCreation() public view {
        assertTrue(hcaModule.isInitialized(hcaAccount));
    }

    function test_createAccount_reInitReverts() public {
        OwnableValidator.Owner[] memory owners = new OwnableValidator.Owner[](1);
        owners[0] = OwnableValidator.Owner({ addr: owner1, expiration: type(uint48).max });
        bytes memory initData = abi.encode(uint256(1), owners);

        // initializeAccount should revert because tstore flag is cleared after deploy tx
        vm.expectRevert();
        HCA(hcaAccount).initializeAccount(initData);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Module Locking
    // ══════════════════════════════════════════════════════════════════════

    function test_installModule_revertsFromEntryPoint() public {
        vm.prank(entryPoint);
        vm.expectRevert(HCA.NoModuleChangeAllowed.selector);
        HCA(hcaAccount).installModule(1, address(0xdead), "");
    }

    function test_installModule_revertsFromOwner() public {
        vm.prank(owner1);
        vm.expectRevert(HCA.NoModuleChangeAllowed.selector);
        HCA(hcaAccount).installModule(1, address(0xdead), "");
    }

    function test_installModule_revertsFromRandom() public {
        vm.prank(random);
        vm.expectRevert(HCA.NoModuleChangeAllowed.selector);
        HCA(hcaAccount).installModule(1, address(0xdead), "");
    }

    function test_uninstallModule_revertsFromEntryPoint() public {
        vm.prank(entryPoint);
        vm.expectRevert(HCA.NoModuleChangeAllowed.selector);
        HCA(hcaAccount).uninstallModule(1, address(0xdead), "");
    }

    function test_uninstallModule_revertsFromOwner() public {
        vm.prank(owner1);
        vm.expectRevert(HCA.NoModuleChangeAllowed.selector);
        HCA(hcaAccount).uninstallModule(1, address(0xdead), "");
    }

    function test_uninstallModule_revertsFromRandom() public {
        vm.prank(random);
        vm.expectRevert(HCA.NoModuleChangeAllowed.selector);
        HCA(hcaAccount).uninstallModule(1, address(0xdead), "");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  NFT Transfer Rejection
    // ══════════════════════════════════════════════════════════════════════

    function test_safeTransferFrom_erc721_reverts() public {
        uint256 tokenId = nft.mint(address(this));
        vm.expectRevert(HCA.NoNFTAllowed.selector);
        nft.safeTransferFrom(address(this), hcaAccount, tokenId);
    }

    function test_safeTransferFrom_erc1155_reverts() public {
        multiToken.mint(address(this), 1, 10);
        vm.expectRevert(HCA.NoNFTAllowed.selector);
        multiToken.safeTransferFrom(address(this), hcaAccount, 1, 5, "");
    }

    function test_safeBatchTransferFrom_erc1155_reverts() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10;
        amounts[1] = 20;
        multiToken.mintBatch(address(this), ids, amounts);

        vm.expectRevert(HCA.NoNFTAllowed.selector);
        multiToken.safeBatchTransferFrom(address(this), hcaAccount, ids, amounts, "");
    }

    function test_ethTransfer_succeeds() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = hcaAccount.call{ value: 1 ether }("");
        assertTrue(success);
        assertEq(hcaAccount.balance, 1 ether);
    }

    function test_erc20Transfer_succeeds() public {
        erc20.mint(address(this), 100 ether);
        erc20.transfer(hcaAccount, 50 ether);
        assertEq(erc20.balanceOf(hcaAccount), 50 ether);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Account Upgrade
    // ══════════════════════════════════════════════════════════════════════

    function test_upgrade_toFactoryImpl_succeedsViaEntryPoint() public {
        // Deploy new implementation
        HCA newImpl = _deployNewHCAImpl();

        // Update factory to point to new impl
        vm.prank(factoryOwner);
        factory.setImplementation(address(newImpl), IHCAInitDataParser(address(hcaModule)));

        // Upgrade via entryPoint
        vm.prank(entryPoint);
        HCA(hcaAccount).upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_toArbitraryAddress_reverts() public {
        address arbitrary = makeAddr("arbitrary");

        // UUPS checks for valid implementation before _authorizeUpgrade
        vm.prank(entryPoint);
        vm.expectRevert();
        HCA(hcaAccount).upgradeToAndCall(arbitrary, "");
    }

    function test_upgrade_fromRandom_reverts() public {
        vm.prank(random);
        vm.expectRevert();
        HCA(hcaAccount).upgradeToAndCall(address(hcaImpl), "");
    }

    function test_upgrade_afterFactoryUpdate_succeeds() public {
        // Deploy new impl and update factory
        HCA newImpl = _deployNewHCAImpl();
        vm.prank(factoryOwner);
        factory.setImplementation(address(newImpl), IHCAInitDataParser(address(hcaModule)));

        // Upgrade succeeds
        vm.prank(entryPoint);
        HCA(hcaAccount).upgradeToAndCall(address(newImpl), "");

        // Verify the account still works (module still initialized)
        assertTrue(hcaModule.isInitialized(hcaAccount));
    }

    function test_upgrade_toOldImpl_revertsAfterFactoryUpdate() public {
        // Deploy new impl and update factory
        HCA newImpl = _deployNewHCAImpl();
        vm.prank(factoryOwner);
        factory.setImplementation(address(newImpl), IHCAInitDataParser(address(hcaModule)));

        // Trying to upgrade to the OLD implementation should revert
        vm.prank(entryPoint);
        vm.expectRevert(abi.encodeWithSelector(HCA.InvalidHCAUpgrade.selector, address(hcaImpl)));
        HCA(hcaAccount).upgradeToAndCall(address(hcaImpl), "");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Initialization Validation
    // ══════════════════════════════════════════════════════════════════════

    function test_init_firstOwnerMustBePermanent() public {
        OwnableValidator.Owner[] memory owners = new OwnableValidator.Owner[](1);
        owners[0] =
            OwnableValidator.Owner({ addr: owner2, expiration: uint48(block.timestamp + 1 days) });
        bytes memory initData = abi.encode(uint256(1), owners);

        // CREATE3 wraps inner reverts as DeploymentFailed()
        vm.expectRevert();
        factory.createAccount(initData);
    }

    function test_init_zeroThresholdReverts() public {
        OwnableValidator.Owner[] memory owners = new OwnableValidator.Owner[](1);
        owners[0] = OwnableValidator.Owner({ addr: owner2, expiration: type(uint48).max });
        bytes memory initData = abi.encode(uint256(0), owners);

        vm.expectRevert();
        factory.createAccount(initData);
    }

    function test_init_thresholdGtOwnersReverts() public {
        OwnableValidator.Owner[] memory owners = new OwnableValidator.Owner[](1);
        owners[0] = OwnableValidator.Owner({ addr: owner2, expiration: type(uint48).max });
        bytes memory initData = abi.encode(uint256(2), owners);

        vm.expectRevert();
        factory.createAccount(initData);
    }

    function test_init_zeroAddressOwnerReverts() public {
        OwnableValidator.Owner[] memory owners = new OwnableValidator.Owner[](1);
        owners[0] = OwnableValidator.Owner({ addr: address(0), expiration: type(uint48).max });
        bytes memory initData = abi.encode(uint256(1), owners);

        vm.expectRevert();
        factory.createAccount(initData);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Multi-owner + Factory Admin
    // ══════════════════════════════════════════════════════════════════════

    function test_multiOwner_validConfig() public {
        // First owner determines the account address via getOwnerFromInitData,
        // so use owner2 (not owner1 which already has an account)
        OwnableValidator.Owner[] memory owners = new OwnableValidator.Owner[](3);
        owners[0] = OwnableValidator.Owner({ addr: owner2, expiration: type(uint48).max });
        owners[1] = OwnableValidator.Owner({ addr: owner1, expiration: type(uint48).max });
        owners[2] = OwnableValidator.Owner({
            addr: owner3, expiration: uint48(block.timestamp + 365 days)
        });
        bytes memory initData = abi.encode(uint256(2), owners);

        address payable multiAccount = factory.createAccount(initData);

        assertTrue(hcaModule.isInitialized(multiAccount));
        assertEq(hcaModule.thresholds(multiAccount), 2);
        assertEq(hcaModule.getOwnersCount(multiAccount), 3);
        assertTrue(hcaModule.isOwner(multiAccount, owner1));
        assertTrue(hcaModule.isOwner(multiAccount, owner2));
        assertTrue(hcaModule.isOwner(multiAccount, owner3));
    }

    function test_getAccountOwner_returnsZeroForNonAccount() public view {
        assertEq(factory.getAccountOwner(random), address(0));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Executor
    // ══════════════════════════════════════════════════════════════════════

    function test_executeFromExecutor_succeeds() public {
        // Fund the HCA so it can send ETH
        vm.deal(hcaAccount, 1 ether);

        ExecutionMode mode = ModeLib.encodeSimpleSingle();
        bytes memory execData = abi.encodePacked(random, uint256(0.5 ether), "");

        vm.prank(address(executor));
        HCA(hcaAccount).executeFromExecutor(mode, execData);

        assertEq(random.balance, 0.5 ether);
    }

    function test_executeFromExecutor_revertsFromNonExecutor() public {
        ExecutionMode mode = ModeLib.encodeSimpleSingle();
        bytes memory execData = abi.encodePacked(random, uint256(0), "");

        vm.prank(random);
        vm.expectRevert();
        HCA(hcaAccount).executeFromExecutor(mode, execData);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Adversarial / Coverage
    // ══════════════════════════════════════════════════════════════════════

    function test_constructor_zeroFactory_reverts() public {
        OwnableValidator.Owner[] memory owners = new OwnableValidator.Owner[](1);
        owners[0] = OwnableValidator.Owner({ addr: address(1), expiration: type(uint48).max });
        bytes memory template = abi.encode(uint256(1), owners);

        vm.expectRevert(HCA.HCAFactoryCannotBeZero.selector);
        new HCA(
            IHCAFactory(address(0)), entryPoint, address(hcaModule), address(executor), template
        );
    }

    function test_fallback_nonNFTSelector_forwards() public {
        // Call a random selector that isn't
        // onERC721Received/onERC1155Received/onERC1155BatchReceived Should hit super._fallback,
        // which looks for a registered fallback handler.
        // No handler registered → reverts with MissingFallbackHandler or similar
        vm.expectRevert();
        (bool success,) = hcaAccount.call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
        // If expectRevert catches it, we're good — super._fallback was reached
    }

    function test_getOwnerFromInitData_emptyOwners_reverts() public {
        OwnableValidator.Owner[] memory empty = new OwnableValidator.Owner[](0);
        bytes memory initData = abi.encode(uint256(1), empty);

        vm.expectRevert(HCAModule.InvalidInitializationData.selector);
        hcaModule.getOwnerFromInitData(initData);
    }

    function test_onInstall_emptyOwners_reverts() public {
        OwnableValidator.Owner[] memory empty = new OwnableValidator.Owner[](0);
        bytes memory initData = abi.encode(uint256(1), empty);

        vm.expectRevert();
        factory.createAccount(initData);
    }

    function test_hcaModule_name() public view {
        assertEq(hcaModule.name(), "HCAModule");
    }

    function test_implementation_initializeAccount_reverts() public {
        // Direct call to the implementation (not via proxy) should revert
        OwnableValidator.Owner[] memory owners = new OwnableValidator.Owner[](1);
        owners[0] = OwnableValidator.Owner({ addr: owner1, expiration: type(uint48).max });
        bytes memory initData = abi.encode(uint256(1), owners);

        vm.expectRevert();
        hcaImpl.initializeAccount(initData);
    }

    function test_executorCannotUpgrade() public {
        HCA newImpl = _deployNewHCAImpl();
        vm.prank(factoryOwner);
        factory.setImplementation(address(newImpl), IHCAInitDataParser(address(hcaModule)));

        // Executor calling upgradeToAndCall directly should revert (not entryPoint or self)
        vm.prank(address(executor));
        vm.expectRevert();
        HCA(hcaAccount).upgradeToAndCall(address(newImpl), "");
    }

    function test_idempotentCreate_forwardsValue() public {
        OwnableValidator.Owner[] memory owners = new OwnableValidator.Owner[](1);
        owners[0] = OwnableValidator.Owner({ addr: owner1, expiration: type(uint48).max });
        bytes memory initData = abi.encode(uint256(1), owners);

        uint256 balBefore = hcaAccount.balance;
        factory.createAccount{ value: 0.5 ether }(initData);
        assertEq(hcaAccount.balance, balBefore + 0.5 ether);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  Owner CRUD via execute + Invariants
    // ══════════════════════════════════════════════════════════════════════

    function _execOnModule(address account, bytes memory callData) internal {
        bytes memory execCalldata = abi.encodePacked(address(hcaModule), uint256(0), callData);
        vm.prank(entryPoint);
        HCA(payable(account)).execute(ModeLib.encodeSimpleSingle(), execCalldata);
    }

    function _assertModuleInvariant(address account) internal view {
        uint256 threshold = hcaModule.thresholds(account);
        uint256 count = hcaModule.getOwnersCount(account);
        assertTrue(count >= 1, "invariant: ownerCount >= 1");
        assertTrue(threshold >= 1, "invariant: threshold >= 1");
        assertTrue(threshold <= count, "invariant: threshold <= ownerCount");
    }

    function test_updateConfig_addOwner_invariantHolds() public {
        // Add owner2 to the single-owner account, bump threshold to 2
        OwnableValidator.Owner[] memory toAdd = new OwnableValidator.Owner[](1);
        toAdd[0] = OwnableValidator.Owner({ addr: owner2, expiration: type(uint48).max });
        address[] memory toRemove = new address[](0);

        _execOnModule(
            hcaAccount, abi.encodeCall(OwnableValidator.updateConfig, (2, toAdd, toRemove))
        );

        assertEq(hcaModule.thresholds(hcaAccount), 2);
        assertEq(hcaModule.getOwnersCount(hcaAccount), 2);
        assertTrue(hcaModule.isOwner(hcaAccount, owner2));
        _assertModuleInvariant(hcaAccount);
    }

    function test_updateConfig_removeOwner_invariantHolds() public {
        // First add owner2 (threshold=1, 2 owners)
        OwnableValidator.Owner[] memory toAdd = new OwnableValidator.Owner[](1);
        toAdd[0] = OwnableValidator.Owner({ addr: owner2, expiration: type(uint48).max });
        address[] memory empty = new address[](0);
        _execOnModule(hcaAccount, abi.encodeCall(OwnableValidator.updateConfig, (1, toAdd, empty)));

        // Now remove owner2, keep threshold=1
        OwnableValidator.Owner[] memory noAdd = new OwnableValidator.Owner[](0);
        address[] memory toRemove = new address[](1);
        toRemove[0] = owner2;
        _execOnModule(
            hcaAccount, abi.encodeCall(OwnableValidator.updateConfig, (1, noAdd, toRemove))
        );

        assertEq(hcaModule.getOwnersCount(hcaAccount), 1);
        assertFalse(hcaModule.isOwner(hcaAccount, owner2));
        _assertModuleInvariant(hcaAccount);
    }

    function test_updateConfig_removeAllOwners_reverts() public {
        // Try to remove the only owner — should break invariant and revert
        OwnableValidator.Owner[] memory noAdd = new OwnableValidator.Owner[](0);
        address[] memory toRemove = new address[](1);
        toRemove[0] = owner1;

        vm.expectRevert();
        _execOnModule(
            hcaAccount, abi.encodeCall(OwnableValidator.updateConfig, (1, noAdd, toRemove))
        );

        // State unchanged
        assertEq(hcaModule.getOwnersCount(hcaAccount), 1);
        assertTrue(hcaModule.isOwner(hcaAccount, owner1));
    }

    function test_updateConfig_thresholdGtOwners_reverts() public {
        // Try threshold=3 with only 1 owner
        OwnableValidator.Owner[] memory noAdd = new OwnableValidator.Owner[](0);
        address[] memory noRemove = new address[](0);

        vm.expectRevert();
        _execOnModule(
            hcaAccount, abi.encodeCall(OwnableValidator.updateConfig, (3, noAdd, noRemove))
        );

        // Threshold unchanged
        assertEq(hcaModule.thresholds(hcaAccount), 1);
    }

    function test_updateConfig_zeroThreshold_reverts() public {
        OwnableValidator.Owner[] memory noAdd = new OwnableValidator.Owner[](0);
        address[] memory noRemove = new address[](0);

        vm.expectRevert();
        _execOnModule(
            hcaAccount, abi.encodeCall(OwnableValidator.updateConfig, (0, noAdd, noRemove))
        );

        assertEq(hcaModule.thresholds(hcaAccount), 1);
    }

    function test_updateConfig_swapOwner_invariantHolds() public {
        // Atomic swap: remove owner1, add owner2, keep threshold=1
        OwnableValidator.Owner[] memory toAdd = new OwnableValidator.Owner[](1);
        toAdd[0] = OwnableValidator.Owner({ addr: owner2, expiration: type(uint48).max });
        address[] memory toRemove = new address[](1);
        toRemove[0] = owner1;

        _execOnModule(
            hcaAccount, abi.encodeCall(OwnableValidator.updateConfig, (1, toAdd, toRemove))
        );

        assertEq(hcaModule.getOwnersCount(hcaAccount), 1);
        assertFalse(hcaModule.isOwner(hcaAccount, owner1));
        assertTrue(hcaModule.isOwner(hcaAccount, owner2));
        _assertModuleInvariant(hcaAccount);
    }

    function test_updateConfig_addZeroAddress_reverts() public {
        OwnableValidator.Owner[] memory toAdd = new OwnableValidator.Owner[](1);
        toAdd[0] = OwnableValidator.Owner({ addr: address(0), expiration: type(uint48).max });
        address[] memory noRemove = new address[](0);

        vm.expectRevert();
        _execOnModule(
            hcaAccount, abi.encodeCall(OwnableValidator.updateConfig, (1, toAdd, noRemove))
        );
    }

    function test_updateOwnerExpiration_works() public {
        uint48 newExp = uint48(block.timestamp + 30 days);

        _execOnModule(
            hcaAccount, abi.encodeCall(OwnableValidator.updateOwnerExpiration, (owner1, newExp))
        );

        assertEq(hcaModule.getOwnerExpiration(hcaAccount, owner1), newExp);
        _assertModuleInvariant(hcaAccount);
    }

    function test_updateOwnerExpiration_pastTimestamp_reverts() public {
        vm.warp(1000);
        uint48 pastExp = uint48(block.timestamp - 1);

        vm.expectRevert();
        _execOnModule(
            hcaAccount, abi.encodeCall(OwnableValidator.updateOwnerExpiration, (owner1, pastExp))
        );

        // Expiration unchanged (still permanent)
        assertEq(hcaModule.getOwnerExpiration(hcaAccount, owner1), type(uint48).max);
    }

    function test_updateOwnerExpiration_nonExistentOwner_reverts() public {
        vm.expectRevert();
        _execOnModule(
            hcaAccount,
            abi.encodeCall(OwnableValidator.updateOwnerExpiration, (owner2, type(uint48).max))
        );
    }

    function test_updateConfig_removeOwnerBelowThreshold_reverts() public {
        // Set up 2 owners, threshold 2
        OwnableValidator.Owner[] memory toAdd = new OwnableValidator.Owner[](1);
        toAdd[0] = OwnableValidator.Owner({ addr: owner2, expiration: type(uint48).max });
        address[] memory empty = new address[](0);
        _execOnModule(hcaAccount, abi.encodeCall(OwnableValidator.updateConfig, (2, toAdd, empty)));
        assertEq(hcaModule.thresholds(hcaAccount), 2);

        // Try to remove owner2 without lowering threshold — should revert
        OwnableValidator.Owner[] memory noAdd = new OwnableValidator.Owner[](0);
        address[] memory toRemove = new address[](1);
        toRemove[0] = owner2;

        vm.expectRevert();
        _execOnModule(
            hcaAccount, abi.encodeCall(OwnableValidator.updateConfig, (2, noAdd, toRemove))
        );

        // State unchanged
        assertEq(hcaModule.getOwnersCount(hcaAccount), 2);
        _assertModuleInvariant(hcaAccount);
    }

    function test_updateConfig_notCallableByRandom() public {
        OwnableValidator.Owner[] memory noAdd = new OwnableValidator.Owner[](0);
        address[] memory noRemove = new address[](0);

        // Random can't call execute on the HCA
        vm.prank(random);
        vm.expectRevert();
        HCA(hcaAccount)
            .execute(
                ModeLib.encodeSimpleSingle(),
                abi.encodePacked(
                    address(hcaModule),
                    uint256(0),
                    abi.encodeCall(OwnableValidator.updateConfig, (1, noAdd, noRemove))
                )
            );
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────────────────

    function _deployNewHCAImpl() internal returns (HCA) {
        OwnableValidator.Owner[] memory templateOwners = new OwnableValidator.Owner[](1);
        templateOwners[0] =
            OwnableValidator.Owner({ addr: address(2), expiration: type(uint48).max });
        bytes memory template = abi.encode(uint256(1), templateOwners);

        return new HCA(
            IHCAFactory(address(factory)),
            entryPoint,
            address(hcaModule),
            address(executor),
            template
        );
    }
}

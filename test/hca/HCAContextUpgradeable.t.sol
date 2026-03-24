// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// solhint-disable func-name-mixedcase

import { Test } from "forge-std/Test.sol";

import { HCAContextUpgradeable } from "@ensdomains/contracts-v2/src/hca/HCAContextUpgradeable.sol";
import { HCAEquivalence } from "@ensdomains/contracts-v2/src/hca/HCAEquivalence.sol";
import { IHCAFactoryBasic } from "@ensdomains/contracts-v2/src/hca/interfaces/IHCAFactoryBasic.sol";
import { MockHCAFactoryBasic } from "./mocks/MockHCAFactoryBasic.sol";

contract HCAContextUpgradeableHarness is HCAContextUpgradeable {
    constructor(IHCAFactoryBasic factory) HCAEquivalence(factory) { }

    function exposedMsgSender() external view returns (address) {
        return _msgSender();
    }
}

contract HCAContextUpgradeableTest is Test {
    MockHCAFactoryBasic factory;
    HCAContextUpgradeableHarness harness;

    address user = address(0x1111);
    address hca = address(0xAAAA);
    address owner = address(0xBEEF);

    function setUp() public {
        factory = new MockHCAFactoryBasic();
        harness = new HCAContextUpgradeableHarness(factory);
    }

    function test_constructor_sets_factory() public view {
        assertEq(address(harness.HCA_FACTORY()), address(factory));
    }

    function test_msgSender_calls_HCAEquivalence() public {
        vm.prank(user);
        vm.expectCall(
            address(factory), abi.encodeWithSelector(factory.getAccountOwner.selector, user)
        );
        address sender = harness.exposedMsgSender();
        assertEq(sender, user);
    }
}

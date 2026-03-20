// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import {
    IHCAInitDataParser
} from "@ensdomains/contracts-v2/src/hca/interfaces/IHCAInitDataParser.sol";
import { OwnableValidator } from "./base/OwnableValidator.sol";

contract HCAModule is IHCAInitDataParser, OwnableValidator {
    error InvalidInitializationData();

    function getOwnerFromInitData(bytes calldata initData)
        external
        view
        returns (address hcaOwner)
    {
        (uint256 threshold, Owner[] memory newOwners) = abi.decode(initData, (uint256, Owner[]));
        require(newOwners.length > 0, InvalidInitializationData());
        hcaOwner = newOwners[0].addr;
    }

    function _onInstall(uint256 threshold, Owner[] memory newOwners) internal virtual override {
        require(newOwners.length > 0, InvalidInitializationData());
        require(newOwners[0].expiration == type(uint48).max, InvalidInitializationData());
        super._onInstall(threshold, newOwners);
    }

    function name() external pure virtual override returns (string memory) {
        return "HCAModule";
    }
}

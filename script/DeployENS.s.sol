// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import { ENSValidator } from "src/validator/ENSValidator.sol";
import { MockENS } from "src/mocks/MockENS.sol";
import { console2 } from "forge-std/console2.sol";

/// @title DeployENSScript
/// @notice Deployment script for ENSValidator and MockENS contracts
contract DeployENSScript is Script {
    function run() public {
        // Get private key for deployment
        uint256 deployerPrivateKey = vm.envUint("PK");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MockENS first (if needed for testing)
        address token;
        require(token != address(0), "set a token");

        MockENS mockENS;
        if (token != address(0)) {
            mockENS = new MockENS(token);
            console.log("MockENS deployed at:", address(mockENS));
        } else {
            console.log("Skipping MockENS deployment (no MOCK_TOKEN set)");
        }

        // Deploy ENSValidator
        ENSValidator ensValidator = new ENSValidator();
        console.log("ENSValidator deployed at:", address(ensValidator));

        vm.stopBroadcast();

        // Log deployment info
        console.log("\n=== Deployment Summary ===");
        if (token != address(0)) {
            console.log("MockENS:", address(mockENS));
        }
        console.log("ENSValidator:", address(ensValidator));
        console.log("========================\n");
    }
}

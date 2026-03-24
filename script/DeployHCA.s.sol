// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import { HCA } from "src/hca/HCA.sol";
import { HCAModule } from "src/hca-module/HCAModule.sol";
import { OwnableValidator } from "src/hca-module/base/OwnableValidator.sol";
import { HCAFactory } from "@ensdomains/contracts-v2/src/hca/HCAFactory.sol";
import { IHCAFactory } from "@ensdomains/contracts-v2/src/hca/interfaces/IHCAFactory.sol";
import { IHCAInitDataParser } from "@ensdomains/contracts-v2/src/hca/interfaces/IHCAInitDataParser.sol";

/// @title DeployHCA
/// @notice Deploys the full HCA stack: HCAModule, HCAFactory, and HCA implementation.
contract DeployHCA is Script {
    address constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant FACTORY_OWNER = 0x61e8AC0a758AfEEFBD556f713ecF0A8cbd00288f;
    address constant INTENT_EXECUTOR = 0xbF9b5b917a83f8adaC17B0752846D41D8D7b7E17;

    function run() public {
        vm.startBroadcast();

        // 1. Deploy HCAModule (validator + init data parser)
        HCAModule hcaModule = new HCAModule();

        // 2. Deploy HCAFactory with zero implementation initially
        HCAFactory factory = new HCAFactory(address(0), IHCAInitDataParser(address(hcaModule)), FACTORY_OWNER);

        // 3. Build template init data to block the implementation from direct use
        OwnableValidator.Owner[] memory templateOwners = new OwnableValidator.Owner[](1);
        templateOwners[0] = OwnableValidator.Owner({ addr: address(1), expiration: type(uint48).max });
        bytes memory validatorInitData = abi.encode(uint256(1), templateOwners);

        // 4. Deploy HCA implementation
        HCA hcaImpl = new HCA(IHCAFactory(address(factory)), ENTRY_POINT, address(hcaModule), INTENT_EXECUTOR, validatorInitData);

        // 5. Register implementation on the factory
        factory.setImplementation(address(hcaImpl), IHCAInitDataParser(address(hcaModule)));
        vm.stopBroadcast();

        console.log("\n=== HCA Deployment ===");
        console.log("HCAModule:   ", address(hcaModule));
        console.log("HCAFactory:  ", address(factory));
        console.log("HCA (impl):  ", address(hcaImpl));
        console.log("EntryPoint:  ", ENTRY_POINT);
        console.log("IntentExec:  ", INTENT_EXECUTOR);
        console.log("FactoryOwner:", FACTORY_OWNER);
        console.log("======================\n");
    }
}

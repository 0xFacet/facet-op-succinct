// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {Rollup} from "../src/Rollup.sol";
import {L1Bridge} from "../src/L1Bridge.sol";
import {L2Bridge} from "../src/L2Bridge.sol";
import {FacetScript} from "lib/facet-sol/src/foundry-utils/FacetScript.sol";

contract DeployBridges is Script, FacetScript {
    function run() external broadcast {
        // Read existing Rollup address from environment
        address rollupAddress = vm.envAddress("ROLLUP_ADDRESS");
        
        Rollup rollup = Rollup(rollupAddress);
        console.log("\n=== Using existing Rollup at:", rollupAddress, "===");
        
        // Deploy L1 Bridge
        console.log("\n=== Deploying L1 Bridge ===");
        L1Bridge l1Bridge = new L1Bridge(rollup);
        console.log("L1 Bridge deployed at:", address(l1Bridge));
        
        // Deploy L2 Bridge using Facet approach
        console.log("\n=== Deploying L2 Bridge via Facet ===");
        address l2BridgeAddress = deployL2BridgeViaFacet(address(l1Bridge));
        
        // Link bridges
        console.log("\n=== Linking Bridges ===");
        l1Bridge.setL2Bridge(l2BridgeAddress);
        console.log("L1 Bridge linked to L2 Bridge at:", l2BridgeAddress);
        
        // Renounce ownership if requested
        console.log("Renouncing bridge ownership");
        l1Bridge.renounceOwnership();
        
        // Output deployment summary
        console.log("\n========================================");
        console.log("Deployment Summary");
        console.log("========================================");
        console.log("Existing Rollup:", rollupAddress);
        console.log("L1 Bridge:", address(l1Bridge));
        console.log("L2 Bridge:", l2BridgeAddress);
        console.log("========================================\n");
        
        // Output configuration for withdrawal script
        console.log("Configuration for withdrawal script:");
        console.log("export L1_BRIDGE_ADDRESS='%s'", address(l1Bridge));
        console.log("export ROLLUP_ADDRESS='%s'", rollupAddress);
        console.log("export L2_BRIDGE_ADDRESS='%s'", l2BridgeAddress);
    }
    
    function deployL2BridgeViaFacet(address l1BridgeAddress) internal returns (address) {
        // L2Bridge constructor takes (string name, string symbol, address l1Bridge)
        bytes memory constructorArgs = abi.encode(
            "Bluebird WETH",
            "BBWETH",
            l1BridgeAddress
        );
        return deployContract("L2Bridge", type(L2Bridge).creationCode, constructorArgs);
    }
    
    function deployContract(string memory _name, bytes memory _creationCode, bytes memory _initData) public returns (address addr_) {
        addr_ = nextL2Address();
        console.log(string.concat("Deploying contract ", _name));
        sendFacetTransactionFoundry({
            gasLimit: 20_000_000,
            data: abi.encodePacked(_creationCode, _initData)
        });
        console.log("   at %s", addr_);
    }
}
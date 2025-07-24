// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {Rollup} from "../src/Rollup.sol";
import {L1Bridge} from "../src/L1Bridge.sol";
import {L2Bridge} from "../src/L2Bridge.sol";
import {ISP1Verifier} from "@sp1-contracts/src/ISP1Verifier.sol";
import {SP1MockVerifier} from "@sp1-contracts/src/SP1MockVerifier.sol";
import {LibFacet} from "facet-sol/src/utils/LibFacet.sol";
import { FacetScript } from "lib/facet-sol/src/foundry-utils/FacetScript.sol";

contract DeployRollupAndBridges is Script, FacetScript {
    using LibString for uint256;

    function run() external broadcast {
        // Read environment variables
        bool useMockVerifier = vm.envOr("USE_SP1_MOCK_VERIFIER", false);
        
        // Deploy everything
        
        // Step 1: Deploy Rollup
        console.log("\n=== Deploying Rollup ===");
        address verifierAddr = deployVerifier(useMockVerifier);
        Rollup rollup = deployRollup(verifierAddr, useMockVerifier);
        
        // Step 2: Deploy L1 Bridge
        console.log("\n=== Deploying L1 Bridge ===");
        L1Bridge l1Bridge = new L1Bridge(Rollup(address(rollup)));
        console.log("L1 Bridge deployed at:", address(l1Bridge));
        
        // Step 3: Deploy L2 Bridge using Facet approach
        console.log("\n=== Deploying L2 Bridge via Facet ===");
        address l2BridgeAddress = deployL2BridgeViaFacet(address(l1Bridge));
        
        // Step 4: Link bridges
        console.log("\n=== Linking Bridges ===");
        l1Bridge.setL2Bridge(l2BridgeAddress);
        console.log("L1 Bridge linked to L2 Bridge at:", l2BridgeAddress);
        
        console.log("Renouncing bridge ownership");
        l1Bridge.renounceOwnership();
        
        // Step 5: Configure Rollup permissions
        console.log("\n=== Configuring Rollup Permissions ===");
        configureRollupPermissions(rollup);
        
        // Step 6: Transfer ownership
        address finalOwner = vm.envAddress("ROLLUP_OWNER");
        rollup.transferOwnership(finalOwner);
        console.log("Transferred Rollup ownership to:", finalOwner);
        
        // Output deployment summary
        console.log("\n========================================");
        console.log("Deployment Summary");
        console.log("========================================");
        console.log("Rollup:", address(rollup));
        console.log("L1 Bridge:", address(l1Bridge));
        console.log("L2 Bridge:", l2BridgeAddress);
        console.log("SP1 Verifier:", verifierAddr);
        console.log("========================================\n");
        
        // Output configuration for withdrawal script
        console.log("Configuration for withdrawal script:");
        console.log("export L1_BRIDGE_ADDRESS='%s'", address(l1Bridge));
        console.log("export ROLLUP_ADDRESS='%s'", address(rollup));
        console.log("export L2_BRIDGE_ADDRESS='%s'", l2BridgeAddress);
    }
    
    function deployVerifier(bool useMockVerifier) internal returns (address) {
        if (useMockVerifier) {
            SP1MockVerifier mock = new SP1MockVerifier();
            console.log("Mock Verifier deployed at:", address(mock));
            return address(mock);
        } else {
            address verifierAddr = vm.envAddress("VERIFIER_ADDRESS");
            console.log("Using SP1 Verifier at:", verifierAddr);
            return verifierAddr;
        }
    }
    
    function deployRollup(address verifierAddr, bool useMockVerifier) internal returns (Rollup) {
        // Read Rollup configuration
        bytes32 rollupHash = useMockVerifier ? bytes32(0) : vm.envBytes32("ROLLUP_CONFIG_HASH");
        bytes32 aggVkey = useMockVerifier ? bytes32(0) : vm.envBytes32("AGGREGATION_VKEY");
        bytes32 rangeCommit = useMockVerifier ? bytes32(0) : vm.envBytes32("RANGE_VKEY_COMMITMENT");
        
        Rollup rollup = new Rollup({
            _challengeSecs: vm.envUint("MAX_CHALLENGE_DURATION"),
            _proveSecs: vm.envUint("MAX_PROVE_DURATION"),
            _challengerBond: vm.envUint("CHALLENGER_BOND_WEI"),
            _proposerBond: vm.envUint("PROPOSER_BOND_WEI"),
            _fallbackTimeout: vm.envUint("FALLBACK_TIMEOUT_SECS"),
            _proposalInterval: vm.envUint("PROPOSAL_INTERVAL"),
            _startRoot: vm.envBytes32("STARTING_ROOT"),
            _startBlock: uint128(vm.envUint("STARTING_L2_BLOCK_NUMBER")),
            _l2StartTimestamp: vm.envUint("L2_START_TIMESTAMP"),
            _l2BlockTime: vm.envUint("L2_BLOCK_TIME"),
            _verifier: ISP1Verifier(verifierAddr),
            _rollupHash: rollupHash,
            _aggVkey: aggVkey,
            _rangeCommit: rangeCommit
        });
        
        console.log("Rollup deployed at:", address(rollup));
        return rollup;
    }
    
    function deployL2BridgeViaFacet(address l1BridgeAddress) internal returns (address) {
        // L2Bridge constructor takes (string name, string symbol, address l1Bridge)
        bytes memory constructorArgs = abi.encode(
            "Facet Fun Bucks",  // name
            "FFB",       // symbol  
            l1BridgeAddress
        );
        return deployContract("L2Bridge", type(L2Bridge).creationCode, constructorArgs);
    }
    
    function configureRollupPermissions(Rollup rollup) internal {
        if (vm.envBool("PERMISSIONLESS_MODE")) {
            console.log("Setting permissionless mode");
            rollup.setProposer(address(0), true);
        } else {
            // Add proposers
            string memory proposersStr = vm.envString("PROPOSER_ADDRESSES");
            if (bytes(proposersStr).length > 0) {
                string[] memory proposers = LibString.split(proposersStr, ",");
                for (uint256 i = 0; i < proposers.length; i++) {
                    address proposer = vm.parseAddress(proposers[i]);
                    if (proposer != address(0)) {
                        rollup.setProposer(proposer, true);
                        console.log("Added proposer:", proposer);
                    }
                }
            }
        }
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

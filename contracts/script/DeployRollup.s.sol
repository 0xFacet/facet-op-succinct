// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import {LibString} from "@solady/utils/LibString.sol";

import { Rollup } from "../src/Rollup.sol";
import { ISP1Verifier } from "@sp1-contracts/src/ISP1Verifier.sol";
import { SP1MockVerifier } from "@sp1-contracts/src/SP1MockVerifier.sol";

contract DeployRollup is Script {
    function run() external {
        vm.startBroadcast();

        // Configure verifier
        address verifierAddr;
        bytes32 rollupHash;
        bytes32 aggVkey;
        bytes32 rangeCommit;

        if (vm.envOr("USE_SP1_MOCK_VERIFIER", false)) {
            SP1MockVerifier mock = new SP1MockVerifier();
            verifierAddr = address(mock);
            console.log("Using SP1 Mock Verifier:", verifierAddr);
        } else {
            verifierAddr   = vm.envAddress("VERIFIER_ADDRESS");
            rollupHash     = vm.envBytes32("ROLLUP_CONFIG_HASH");
            aggVkey        = vm.envBytes32("AGGREGATION_VKEY");
            rangeCommit    = vm.envBytes32("RANGE_VKEY_COMMITMENT");
            console.log("Using SP1 Verifier:", verifierAddr);
        }

        Rollup rollup = new Rollup({
            _challengeSecs:    vm.envUint("MAX_CHALLENGE_DURATION"),
            _proveSecs:        vm.envUint("MAX_PROVE_DURATION"),
            _challengerBond:   vm.envUint("CHALLENGER_BOND_WEI"),
            _proposerBond:     vm.envUint("PROPOSER_BOND_WEI"),
            _fallbackTimeout:  vm.envUint("FALLBACK_TIMEOUT_SECS"),
            _startRoot:        vm.envBytes32("STARTING_ROOT"),
            _startBlock:       uint128(vm.envUint("STARTING_L2_BLOCK_NUMBER")),
            _verifier:         ISP1Verifier(verifierAddr),
            _rollupHash:       rollupHash,
            _aggVkey:          aggVkey,
            _rangeCommit:      rangeCommit
        });

        if (vm.envOr("PERMISSIONLESS_MODE", false)) {
            rollup.setProposer(address(0), true); // TODO: transfer to real owner
            console.log("Configured permissionless mode");
        } else {
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

        console.log("Rollup deployed at:", address(rollup));

        vm.stopBroadcast();
    }
} 
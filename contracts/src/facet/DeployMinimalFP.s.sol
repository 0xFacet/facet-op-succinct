// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

// forge-std
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

// Types
import { GameType, Hash, OutputRoot, Duration, Claim } from "../../lib/optimism/packages/contracts-bedrock/src/dispute/lib/Types.sol";

// Core contracts
import { MinimalDisputeGameFactory } from "./MinimalDisputeGameFactory.sol";
import { MinimalAnchorRegistry } from "./MinimalAnchorRegistry.sol";
import { MinimalFaultDisputeGame } from "./MinimalFaultDisputeGame.sol";
import { MinimalAccessManager } from "./MinimalAccessManager.sol";

// Interfaces
import { IDisputeGame } from "../../lib/optimism/packages/contracts-bedrock/interfaces/dispute/IDisputeGame.sol";
import { ISP1Verifier } from "@sp1-contracts/src/ISP1Verifier.sol";

// Utils
import { SP1MockVerifier } from "@sp1-contracts/src/SP1MockVerifier.sol";

contract DeployMinimalFP is Script {
    function run() public {
        vm.startBroadcast();

        // 1. Deploy DisputeGameFactory
        MinimalDisputeGameFactory factory = new MinimalDisputeGameFactory();
        console.log("Factory:", address(factory));

        // 2. Deploy Anchor Registry
        OutputRoot memory startingRoot = OutputRoot({
            root: Hash.wrap(vm.envBytes32("STARTING_ROOT")),
            l2BlockNumber: vm.envUint("STARTING_L2_BLOCK_NUMBER")
        });

        uint256 finalityDelay = vm.envOr("FINALITY_DELAY_SECS", uint256(0));

        MinimalAnchorRegistry registry = new MinimalAnchorRegistry(
            factory,
            finalityDelay,
            startingRoot
        );
        console.log("Anchor Registry:", address(registry));

        // 3. Deploy AccessManager
        uint256 fallbackTimeout = vm.envOr("FALLBACK_TIMEOUT_FP_SECS", uint256(1209600));
        MinimalAccessManager accessManager = new MinimalAccessManager(
            registry,
            fallbackTimeout
        );
        console.log("AccessManager:", address(accessManager));

        // Configure access control
        if (vm.envOr("PERMISSIONLESS_MODE", false)) {
            accessManager.setProposer(address(0), true); // TODO: transfer to real owner
            console.log("Configured permissionless mode");
        }

        // 4. Setup SP1 verifier
        address sp1Verifier;
        bytes32 rollupConfigHash;
        bytes32 aggregationVkey;
        bytes32 rangeVkeyCommitment;

        if (vm.envOr("USE_SP1_MOCK_VERIFIER", false)) {
            SP1MockVerifier mock = new SP1MockVerifier();
            sp1Verifier = address(mock);
            console.log("Using SP1 Mock Verifier:", sp1Verifier);
        } else {
            sp1Verifier = vm.envAddress("VERIFIER_ADDRESS");
            rollupConfigHash = vm.envBytes32("ROLLUP_CONFIG_HASH");
            aggregationVkey = vm.envBytes32("AGGREGATION_VKEY");
            rangeVkeyCommitment = vm.envBytes32("RANGE_VKEY_COMMITMENT");
            console.log("Using SP1 Verifier:", sp1Verifier);
        }

        // 5. Deploy game implementation
        MinimalFaultDisputeGame gameImpl = new MinimalFaultDisputeGame(
            Duration.wrap(uint64(vm.envUint("MAX_CHALLENGE_DURATION"))),
            Duration.wrap(uint64(vm.envUint("MAX_PROVE_DURATION"))),
            factory,
            ISP1Verifier(sp1Verifier),
            rollupConfigHash,
            aggregationVkey,
            rangeVkeyCommitment,
            vm.envOr("CHALLENGER_BOND_WEI", uint256(0.001 ether)),
            registry,
            accessManager
        );
        console.log("Game Implementation:", address(gameImpl));

        // 6. Configure factory
        GameType gameType = GameType.wrap(1);
        factory.setInitBond(gameType, vm.envOr("INITIAL_BOND_WEI", uint256(0.001 ether)));
        factory.setImplementation(gameType, IDisputeGame(address(gameImpl)));

        // 7. Optionally renounce ownership
        if (vm.envOr("RENOUNCE_OWNERSHIP", true)) {
            factory.renounceOwnership();
            console.log("Factory ownership renounced");
        }

        vm.stopBroadcast();
    }
} 
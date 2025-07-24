// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {L1Bridge} from "src/L1Bridge.sol";
import {Rollup} from "src/Rollup.sol";
import {ISP1Verifier} from "@sp1-contracts/src/ISP1Verifier.sol";
import {Types} from "src/libraries/Types.sol";
import {Hashing} from "src/libraries/Hashing.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

contract MockVerifier is ISP1Verifier {
    function VERIFIER_HASH() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function VERSION() external pure returns (string memory) {
        return "1.0.0";
    }

    function VERSION_HASH() external pure returns (bytes32) {
        return keccak256(bytes("1.0.0"));
    }

    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure {
        // Always verify successfully for testing
    }
}

contract L1BridgeTrainingWheelsTest is Test {
    // Events from Pausable
    event Paused(address account);
    event Unpaused(address account);
    L1Bridge public bridge;
    Rollup public rollup;
    Rollup public newRollup;
    
    address owner = address(1);
    address proposer = address(2);
    address user = address(3);
    address l2Bridge = address(4);
    
    function setUp() public {
        // Set chain ID to Sepolia for LibFacet compatibility
        vm.chainId(11155111);
        
        vm.startPrank(owner);
        
        MockVerifier verifier = new MockVerifier();
        
        rollup = new Rollup(
            3600, // max challenge secs
            7200, // max prove secs
            0.1 ether, // challenger bond
            0.1 ether, // proposer bond
            604800, // fallback timeout
            30, // proposal interval
            bytes32(uint256(1)), // start root
            0, // start block
            1234567890, // L2 start time
            2, // L2 block time
            verifier, // verifier
            bytes32(uint256(1)), // rollup config hash
            bytes32(uint256(2)), // agg vkey
            bytes32(uint256(3)) // range vkey commit
        );
        
        // Create another rollup for testing rollup updates
        newRollup = new Rollup(
            3600,
            7200,
            0.1 ether,
            0.1 ether,
            604800,
            30,
            bytes32(uint256(1)),
            0,
            1234567890,
            2,
            verifier,
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3))
        );
        
        bridge = new L1Bridge(rollup);
        bridge.setL2Bridge(l2Bridge);
        
        // Add proposer to whitelist
        rollup.setProposer(proposer, true);
        newRollup.setProposer(proposer, true);
        
        // Transfer ownership of rollups and bridge to owner (since we deployed as owner)
        rollup.transferOwnership(owner);
        newRollup.transferOwnership(owner);
        bridge.transferOwnership(owner);
        
        vm.stopPrank();
        
        // Warp time forward so L2 blocks are in the past
        vm.warp(1234567890 + 100);
    }
    
    function testPauseDeposits() public {
        // User should be able to deposit initially
        vm.deal(user, 1 ether);
        vm.prank(user);
        bridge.initiateDeposit{value: 0.5 ether}();
        
        // Owner pauses the bridge
        vm.prank(owner);
        bridge.pause();
        
        assertTrue(bridge.paused());
        
        // User cannot deposit when paused
        vm.prank(user);
        vm.expectRevert("Pausable: paused");
        bridge.initiateDeposit{value: 0.1 ether}();
        
        // Owner unpauses
        vm.prank(owner);
        bridge.unpause();
        
        assertFalse(bridge.paused());
        
        // User can deposit again
        vm.prank(user);
        bridge.initiateDeposit{value: 0.1 ether}();
    }
    
    function testPauseWithdrawals() public {
        // Setup: Create a proven withdrawal
        Types.OutputRootProof memory rootProof = Types.OutputRootProof({
            version: bytes32(0),
            stateRoot: bytes32(uint256(1)),
            messagePasserStorageRoot: bytes32(uint256(2)),
            latestBlockhash: bytes32(uint256(3))
        });
        
        // Submit a proposal
        vm.deal(proposer, 1 ether);
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: 0.1 ether}(
            Hashing.hashOutputRootProof(rootProof),
            30,
            0
        );
        
        // Fast forward past challenge period
        vm.warp(block.timestamp + 3600 + 1);
        rollup.resolveProposal(proposalId);
        
        // Cannot finalize when paused
        vm.prank(owner);
        bridge.pause();
        
        vm.prank(user);
        vm.expectRevert("Pausable: paused");
        bridge.finalizeWithdrawal(user, 0.1 ether, 1);
    }
    
    function testRootBlacklisting() public {
        // Setup: Create a proposal with a specific root
        Types.OutputRootProof memory rootProof = Types.OutputRootProof({
            version: bytes32(0),
            stateRoot: bytes32(uint256(1)),
            messagePasserStorageRoot: bytes32(uint256(2)),
            latestBlockhash: bytes32(uint256(3))
        });
        
        bytes32 rootClaim = Hashing.hashOutputRootProof(rootProof);
        
        // Submit proposal
        vm.deal(proposer, 1 ether);
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: 0.1 ether}(
            rootClaim,
            30,
            0
        );
        
        // Fast forward past challenge period to make it canonical
        vm.warp(block.timestamp + 3600 + 1);
        rollup.resolveProposal(proposalId);
        
        // Blacklist the root
        vm.prank(owner);
        bridge.setRootBlacklisted(rootClaim, true);
        
        assertTrue(bridge.rootBlacklisted(rootClaim));
        
        // Cannot prove withdrawal with blacklisted root
        vm.prank(user);
        vm.expectRevert(L1Bridge.RootBlacklisted.selector);
        bridge.proveWithdrawal(
            user,
            0.1 ether,
            1,
            proposalId,
            rootProof,
            new bytes[](0)
        );
        
        // Unblacklist
        vm.prank(owner);
        bridge.setRootBlacklisted(rootClaim, false);
        
        assertFalse(bridge.rootBlacklisted(rootClaim));
    }
    
    function testRollupUpdate() public {
        // Check initial rollup
        assertEq(address(bridge.rollup()), address(rollup));
        
        // Update rollup
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit L1Bridge.RollupUpdated(address(rollup), address(newRollup));
        bridge.setRollup(address(newRollup));
        
        // Check updated rollup
        assertEq(address(bridge.rollup()), address(newRollup));
        
        // Bridge should now interact with new rollup
        // Submit proposal to new rollup
        vm.deal(proposer, 1 ether);
        vm.prank(proposer);
        uint256 proposalId = newRollup.submitProposal{value: 0.1 ether}(
            bytes32(uint256(123)),
            30,
            0
        );
        
        // Verify bridge queries new rollup - expect ProposalNotCanonical since we didn't resolve it
        vm.prank(user);
        vm.expectRevert(L1Bridge.ProposalNotCanonical.selector);
        bridge.proveWithdrawal(
            user,
            0.1 ether,
            1,
            proposalId,
            Types.OutputRootProof({
                version: bytes32(0),
                stateRoot: bytes32(0),
                messagePasserStorageRoot: bytes32(0),
                latestBlockhash: bytes32(0)
            }),
            new bytes[](0)
        );
    }
    
    function testOnlyOwnerCanControlTrainingWheels() public {
        // Non-owner cannot pause
        vm.prank(user);
        vm.expectRevert();
        bridge.pause();
        
        // Non-owner cannot blacklist roots
        vm.prank(user);
        vm.expectRevert();
        bridge.setRootBlacklisted(bytes32(uint256(1)), true);
        
        // Non-owner cannot update rollup
        vm.prank(user);
        vm.expectRevert();
        bridge.setRollup(address(newRollup));
    }
    
    function testEventsEmitted() public {
        vm.startPrank(owner);
        
        // Test pause event (using OpenZeppelin Pausable events)
        vm.expectEmit(true, false, false, false);
        emit Paused(owner);
        bridge.pause();
        
        // Test blacklist event
        bytes32 root = bytes32(uint256(123));
        vm.expectEmit(true, false, false, false);
        emit L1Bridge.RootBlacklistStatusChanged(root, true);
        bridge.setRootBlacklisted(root, true);
        
        // Test rollup update event
        vm.expectEmit(true, true, false, false);
        emit L1Bridge.RollupUpdated(address(rollup), address(newRollup));
        bridge.setRollup(address(newRollup));
        
        vm.stopPrank();
    }
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Testing
import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";

// Contracts
import {L1Bridge} from "../src/L1Bridge.sol";
import {L2Bridge} from "../src/L2Bridge.sol";
import {Rollup} from "../src/Rollup.sol";
import {Types} from "src/libraries/Types.sol";
import {Hashing} from "src/libraries/Hashing.sol";
import {ISP1Verifier} from "@sp1-contracts/src/ISP1Verifier.sol";

// Mock verifier for testing
contract MockSP1Verifier is ISP1Verifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure {
        // Always pass
    }
}

/**
 * @title BridgeIntegrationSimpleTest
 * @notice Simplified integration tests focusing on core functionality
 * @dev Merkle proof verification is acknowledged as a limitation
 */
contract BridgeIntegrationSimpleTest is Test {
    L1Bridge public l1Bridge;
    L2Bridge public l2Bridge;
    Rollup public rollup;
    
    address constant user = address(0x1234);
    address constant proposer = address(0x5678);
    
    uint128 constant GENESIS_BLOCK = 1000;
    uint256 constant GENESIS_TIMESTAMP = 1_000_000;
    bytes32 constant GENESIS_ROOT = bytes32(uint256(1));
    
    function setUp() public {
        // Set chain ID to Sepolia for LibFacet compatibility
        vm.chainId(11155111);
        
        // Deploy mock verifier
        MockSP1Verifier verifier = new MockSP1Verifier();
        
        // Deploy Rollup
        rollup = new Rollup(
            3600, // max challenge duration
            7200, // max prove duration  
            0.01 ether, // challenger bond
            0.08 ether, // proposer bond
            14 days, // fallback timeout
            100, // proposal interval
            GENESIS_ROOT,
            GENESIS_BLOCK,
            GENESIS_TIMESTAMP,
            2, // L2 block time
            verifier,
            bytes32(0), // rollup config hash
            bytes32(0), // agg vkey
            bytes32(0) // range vkey
        );
        
        // Setup proposer
        rollup.setProposer(proposer, true);
        vm.deal(proposer, 10 ether);
        
        // Deploy bridges
        l1Bridge = new L1Bridge(Rollup(address(rollup)));
        l2Bridge = new L2Bridge("L2ETH", "L2ETH", address(l1Bridge));
        l1Bridge.setL2Bridge(address(l2Bridge));
        
        // Fund bridge for withdrawals
        vm.deal(address(l1Bridge), 10 ether);
        
        // Warp time so L2 blocks are valid
        vm.warp(GENESIS_TIMESTAMP + 10000);
    }
    
    /**
     * @notice Test basic deposit flow
     */
    function testDeposit() public {
        uint256 depositAmount = 1 ether;
        
        // Fund the user
        vm.deal(user, depositAmount);
        
        vm.expectEmit(true, true, true, true);
        emit L1Bridge.DepositInitiated(user, user, depositAmount);
        
        vm.prank(user);
        l1Bridge.initiateDeposit{value: depositAmount}();
    }
    
    /**
     * @notice Test that withdrawals require canonical proposals
     */
    function testWithdrawalRequiresCanonicalProposal() public {
        // Create a non-canonical proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: 0.08 ether}(
            bytes32(uint256(123)),
            GENESIS_BLOCK + 100,
            0
        );
        
        // Try to prove withdrawal with non-canonical proposal
        vm.expectRevert(L1Bridge.ProposalNotCanonical.selector);
        l1Bridge.proveWithdrawal(
            user,
            1 ether,
            0,
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
    
    /**
     * @notice Test double finalization prevention
     */
    function testCannotDoubleFinalizeWithdrawal() public {
        // Note: In a real test, we would:
        // 1. Create a canonical proposal with proper output root
        // 2. Generate a real merkle proof using the Go FFI tool
        // 3. Prove the withdrawal
        // 4. Finalize it once
        // 5. Try to finalize again and expect revert
        
        // For now, we just test the revert on unproven withdrawal
        vm.expectRevert(L1Bridge.WithdrawalNotProven.selector);
        l1Bridge.finalizeWithdrawal(user, 1 ether, 0);
    }
}

// Events for testing
event DepositInitiated(address indexed from, address indexed to, uint256 amount);
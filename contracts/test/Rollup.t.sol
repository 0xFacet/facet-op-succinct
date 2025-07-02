// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Rollup} from "../src/Rollup.sol";
import {ISP1Verifier} from "@sp1-contracts/src/ISP1Verifier.sol";

contract MockSP1Verifier is ISP1Verifier {
    bool public shouldVerify = true;
    
    function setShouldVerify(bool _should) external {
        shouldVerify = _should;
    }
    
    function verifyProof(
        bytes32,
        bytes calldata,
        bytes calldata
    ) external view {
        require(shouldVerify, "Mock verification failed");
    }
}

contract ReentrantClaimer {
    Rollup public rollup;
    bool public reentered;
    
    constructor(Rollup _rollup) {
        rollup = _rollup;
    }
    
    receive() external payable {
        if (!reentered) {
            reentered = true;
            // Try to claim again during the transfer
            rollup.claimCredit(address(this));
        }
    }
    
    function claim() external {
        rollup.claimCredit(address(this));
    }
}

contract RollupTest is Test {
    Rollup public rollup;
    MockSP1Verifier public verifier;
    
    address public owner = address(this);
    address public proposer = address(0x1);
    address public challenger = address(0x2);
    address public prover = address(0x3);
    
    uint256 constant CHALLENGE_DURATION = 3600;
    uint256 constant PROVE_DURATION = 3600;
    uint256 constant PROPOSER_BOND = 0.08 ether;
    uint256 constant CHALLENGER_BOND = 0.08 ether;
    uint256 constant FALLBACK_TIMEOUT = 86400;
    uint256 constant PROPOSAL_INTERVAL = 100;
    uint256 constant L2_START_TIMESTAMP = 1000;
    uint256 constant L2_BLOCK_TIME = 2;
    
    bytes32 constant ROLLUP_CONFIG_HASH = bytes32(uint256(1));
    bytes32 constant AGGREGATION_VKEY = bytes32(uint256(2));
    bytes32 constant RANGE_VKEY_COMMITMENT = bytes32(uint256(3));
    
    function setUp() public {
        // Set up realistic block environment
        vm.roll(100); // Set block number to 100
        vm.warp(10000); // Set block timestamp to 10000 (well ahead of L2 blocks)
        
        verifier = new MockSP1Verifier();
        
        rollup = new Rollup(
            CHALLENGE_DURATION,
            PROVE_DURATION,
            CHALLENGER_BOND,
            PROPOSER_BOND,
            FALLBACK_TIMEOUT,
            PROPOSAL_INTERVAL,
            bytes32(uint256(100)), // start root
            1000, // start block
            L2_START_TIMESTAMP,
            L2_BLOCK_TIME,
            ISP1Verifier(address(verifier)),
            ROLLUP_CONFIG_HASH,
            AGGREGATION_VKEY,
            RANGE_VKEY_COMMITMENT
        );
        
        // Whitelist proposer
        rollup.setProposer(proposer, true);
        
        // Fund test accounts
        vm.deal(proposer, 10 ether);
        vm.deal(challenger, 10 ether);
        vm.deal(prover, 10 ether);
    }
    
    function testSubmitProposal() public {
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100, // 1000 + PROPOSAL_INTERVAL
            0 // Parent is genesis
        );
        
        assertEq(proposalId, 1); // 0 is genesis
        
        Rollup.Proposal memory proposal = rollup.getProposal(proposalId);
        assertEq(proposal.proposer, proposer);
        assertEq(proposal.rootClaim, bytes32(uint256(200)));
        assertEq(proposal.l2BlockNumber, 1100);
        assertEq(uint8(proposal.proposalStatus), uint8(Rollup.ProposalStatus.Unchallenged));
    }
    
    function testChallengeProposal() public {
        // Submit proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        // Challenge it
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(proposalId);
        
        Rollup.Proposal memory proposal = rollup.getProposal(proposalId);
        assertEq(proposal.challenger, challenger);
        assertEq(uint8(proposal.proposalStatus), uint8(Rollup.ProposalStatus.Challenged));
    }
    
    function testProveProposal() public {
        // Submit and challenge proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(proposalId);
        
        // Prove it
        vm.prank(prover);
        rollup.proveProposal(
            proposalId,
            hex"00" // Mock proof
        );
        
        Rollup.Proposal memory proposal = rollup.getProposal(proposalId);
        assertEq(uint8(proposal.proposalStatus), uint8(Rollup.ProposalStatus.ChallengedAndValidProofProvided));
        assertEq(proposal.prover, prover);
    }
    
    function testResolveUnchallengedProposal() public {
        // Submit proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        // Wait for challenge deadline
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        
        // Resolve
        rollup.resolveProposal(proposalId);
        
        Rollup.Proposal memory proposal = rollup.getProposal(proposalId);
        assertEq(uint8(proposal.resolutionStatus), uint8(Rollup.ResolutionStatus.DEFENDER_WINS));
        assertEq(uint8(proposal.proposalStatus), uint8(Rollup.ProposalStatus.Resolved));
        
        // Check anchor updated
        assertEq(rollup.anchorProposalId(), 1);
        
        // Check proposer got bond back
        assertEq(rollup.credit(proposer), PROPOSER_BOND);
    }
    
    function testResolveChallengedProposalTimeout() public {
        // Submit and challenge proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(proposalId);
        
        // Wait for prove deadline
        vm.warp(block.timestamp + PROVE_DURATION + 1);
        
        // Resolve
        rollup.resolveProposal(proposalId);
        
        Rollup.Proposal memory proposal = rollup.getProposal(proposalId);
        assertEq(uint8(proposal.resolutionStatus), uint8(Rollup.ResolutionStatus.CHALLENGER_WINS));
        
        // Check anchor NOT updated
        assertEq(rollup.anchorProposalId(), 0); // Still genesis
        
        // Check challenger got both bonds
        assertEq(rollup.credit(challenger), PROPOSER_BOND + CHALLENGER_BOND);
    }
    
    function testClaimCredit() public {
        // Submit proposal and let it finalize
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(proposalId);
        
        // Claim credit
        uint256 balanceBefore = proposer.balance;
        vm.prank(proposer);
        rollup.claimCredit(proposer);
        
        assertEq(proposer.balance, balanceBefore + PROPOSER_BOND);
        assertEq(rollup.credit(proposer), 0);
    }
    
    function testFallbackTimeout() public {
        // Initially only whitelisted can propose
        address nonWhitelisted = address(0x999);
        vm.deal(nonWhitelisted, 2 * PROPOSER_BOND);
        
        // Try to propose a recent block (not old enough for permissionless)
        vm.prank(nonWhitelisted);
        vm.expectRevert(Rollup.BadAuth.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)), 
            1100,
            0
        );
        
        // Calculate when block 1100 would be old enough
        // L2 timestamp for block 1100 = L2_START_TIMESTAMP + ((1100 - 1000) * L2_BLOCK_TIME) = 1000 + 200 = 1200
        // For permissionless, we need: block.timestamp - l2Timestamp > FALLBACK_TIMEOUT
        // So we need: block.timestamp > 1200 + FALLBACK_TIMEOUT = 1200 + 86400 = 87600
        vm.warp(87601);
        
        // Now the L2 block 1100 is old enough for permissionless submission
        vm.prank(nonWhitelisted);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        assertEq(proposalId, 1); // 0 is genesis
    }
    
    function testProveUnchallengedProposal() public {
        // Submit proposal (unchallenged)
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        // Prove it even though unchallenged
        vm.prank(prover);
        rollup.proveProposal(proposalId, hex"00");
        
        Rollup.Proposal memory proposal = rollup.getProposal(proposalId);
        assertEq(uint8(proposal.proposalStatus), uint8(Rollup.ProposalStatus.UnchallengedAndValidProofProvided));
    }
    
    function testResolveProvenProposal() public {
        // Submit, challenge, and prove
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(proposalId);
        
        vm.prank(prover);
        rollup.proveProposal(proposalId, hex"00");
        
        // Resolve immediately (proof submitted)
        rollup.resolveProposal(proposalId);
        
        Rollup.Proposal memory proposal = rollup.getProposal(proposalId);
        assertEq(uint8(proposal.resolutionStatus), uint8(Rollup.ResolutionStatus.DEFENDER_WINS));
        
        // Check credits
        assertEq(rollup.credit(prover), CHALLENGER_BOND);
        assertEq(rollup.credit(proposer), PROPOSER_BOND);
    }
    
    function testMultipleProposals() public {
        // Submit first proposal and resolve
        vm.prank(proposer);
        uint256 id1 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(id1);
        
        // Submit second proposal building on first
        vm.prank(proposer);
        uint256 id2 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            1200, // 1100 + PROPOSAL_INTERVAL
            uint32(id1)
        );
        
        Rollup.Proposal memory proposal2 = rollup.getProposal(id2);
        assertEq(proposal2.parentIndex, 1); // Should point to first proposal
    }
    
    function testSelfChallengeAllowed() public {
        // Proposer submits proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        // Proposer can challenge their own proposal (self-challenge is allowed)
        vm.prank(proposer);
        rollup.challengeProposal{value: CHALLENGER_BOND}(proposalId);
        
        Rollup.Proposal memory proposal = rollup.getProposal(proposalId);
        assertEq(proposal.challenger, proposer);
        assertEq(uint8(proposal.proposalStatus), uint8(Rollup.ProposalStatus.Challenged));
    }
    
    function testIncorrectBondAmounts() public {
        // Test incorrect proposer bond
        vm.prank(proposer);
        vm.expectRevert(Rollup.IncorrectBondAmount.selector);
        rollup.submitProposal{value: PROPOSER_BOND - 1}(
            bytes32(uint256(200)), 
            1100,
            0
        );
        
        vm.prank(proposer);
        vm.expectRevert(Rollup.IncorrectBondAmount.selector);
        rollup.submitProposal{value: PROPOSER_BOND + 1}(
            bytes32(uint256(200)), 
            1100,
            0
        );
        
        // Submit valid proposal for challenge test
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        // Test incorrect challenger bond
        vm.prank(challenger);
        vm.expectRevert(Rollup.IncorrectBondAmount.selector);
        rollup.challengeProposal{value: CHALLENGER_BOND - 1}(proposalId);
        
        vm.prank(challenger);
        vm.expectRevert(Rollup.IncorrectBondAmount.selector);
        rollup.challengeProposal{value: CHALLENGER_BOND + 1}(proposalId);
    }
    
    function testInvalidProof() public {
        // Submit and challenge proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(proposalId);
        
        // Set verifier to reject proofs
        verifier.setShouldVerify(false);
        
        // Try to prove - should revert
        vm.prank(prover);
        vm.expectRevert("Mock verification failed");
        rollup.proveProposal(proposalId, hex"00");
    }
    
    function testDoubleClaimCredit() public {
        // Submit proposal and let it finalize
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(proposalId);
        
        // First claim should succeed
        vm.prank(proposer);
        rollup.claimCredit(proposer);
        
        // Second claim should fail
        vm.prank(proposer);
        vm.expectRevert(Rollup.NoCredit.selector);
        rollup.claimCredit(proposer);
    }
    
    function testThirdPartyProver() public {
        address thirdParty = address(0x4);
        vm.deal(thirdParty, 1 ether);
        
        // Submit and challenge proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(proposalId);
        
        // Third party proves
        vm.prank(thirdParty);
        rollup.proveProposal(proposalId, hex"00");
        
        // Resolve
        rollup.resolveProposal(proposalId);
        
        // Check credits - third party gets challenger bond, proposer gets their bond
        assertEq(rollup.credit(thirdParty), CHALLENGER_BOND);
        assertEq(rollup.credit(proposer), PROPOSER_BOND);
        assertEq(rollup.credit(challenger), 0);
    }
    
    function testPermissionlessMode() public {
        // Enable permissionless mode
        rollup.setProposer(address(0), true);
        
        // Any address can now propose
        address anyone = address(0x5555);
        vm.deal(anyone, PROPOSER_BOND);
        
        vm.prank(anyone);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        assertEq(proposalId, 1);
    }
    
    function testCannotInteractWithGenesisProposal() public {
        // Try to challenge genesis proposal
        vm.prank(challenger);
        vm.expectRevert(Rollup.GameNotOver.selector);
        rollup.challengeProposal{value: CHALLENGER_BOND}(0);
        
        // Try to prove genesis proposal
        vm.prank(prover);
        vm.expectRevert(Rollup.GameNotOver.selector);
        rollup.proveProposal(0, hex"00");
        
        // Try to resolve genesis proposal (already resolved)
        vm.expectRevert(Rollup.AlreadyResolved.selector);
        rollup.resolveProposal(0);
    }
    
    function testProposalWithInvalidBlockNumber() public {
        // Try to propose with block number <= anchor
        vm.prank(proposer);
        vm.expectRevert(Rollup.BadCadence.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1000, // Same as genesis block
            0
        );
        
        vm.prank(proposer);
        vm.expectRevert(Rollup.BadCadence.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            999, // Less than genesis block
            0
        );
    }
    
    function testBadCadence() public {
        // Try to propose with wrong interval
        vm.prank(proposer);
        vm.expectRevert(Rollup.BadCadence.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1050, // Not on the interval
            0
        );
    }
    
    function testProposeFutureBlock() public {
        // Try to propose a future block
        vm.prank(proposer);
        vm.expectRevert(Rollup.BadCadence.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            10000, // Way in the future
            0
        );
    }
    
    function testInvalidParentProposal() public {
        // Try to use non-existent parent
        vm.prank(proposer);
        vm.expectRevert(Rollup.InvalidParentGame.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            999 // Non-existent parent
        );
    }
    
    function testParentNotResolved() public {
        // Create first proposal
        vm.prank(proposer);
        uint256 id1 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        // Challenge it so it won't be resolved
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(id1);
        
        // Wait for it to timeout
        vm.warp(block.timestamp + PROVE_DURATION + 1);
        
        // Create second proposal from unresolved parent
        vm.prank(proposer);
        uint256 id2 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            1200,
            uint32(id1)
        );
        
        // Try to resolve child before parent
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        vm.expectRevert(Rollup.ParentGameNotResolved.selector);
        rollup.resolveProposal(id2);
        
        // Resolve parent first
        rollup.resolveProposal(id1);
        
        // Now child can be resolved
        rollup.resolveProposal(id2);
    }
    
    function testParentChallengerWins() public {
        // Create and resolve first proposal as challenger wins
        vm.prank(proposer);
        uint256 id1 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(id1);
        
        vm.warp(block.timestamp + PROVE_DURATION + 1);
        rollup.resolveProposal(id1);
        
        // Try to build on invalid parent
        vm.prank(proposer);
        vm.expectRevert(Rollup.InvalidParentGame.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            1200,
            uint32(id1)
        );
    }
    
    function testReentrancyProtection() public {
        // Setup: proposer gets credit
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(proposalId);
        
        // Deploy reentrant attacker with credit
        ReentrantClaimer attacker = new ReentrantClaimer(rollup);
        
        // Give attacker the credit by having proposer claim to attacker address
        assertEq(rollup.credit(proposer), PROPOSER_BOND);
        
        // Transfer credit internally by resolving another proposal where attacker is proposer
        vm.deal(address(attacker), PROPOSER_BOND);
        rollup.setProposer(address(attacker), true);
        vm.prank(address(attacker));
        uint256 attackerId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            1200,
            1
        );
        
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(attackerId);
        
        // Now attacker has credit
        uint256 attackerCredit = rollup.credit(address(attacker));
        assertEq(attackerCredit, PROPOSER_BOND);
        
        // When attacker tries to claim, it will attempt reentrancy
        // The reentrancy attempt should fail with TransferFailed because
        // the contract uses a direct transfer which has reentrancy protection
        vm.expectRevert(Rollup.TransferFailed.selector);
        attacker.claim();
    }
    
    function testGetterFunctions() public {
        // Create some proposals
        vm.prank(proposer);
        uint256 id1 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        // Test getAnchorProposal
        Rollup.Proposal memory anchorProp = rollup.getAnchorProposal();
        assertEq(anchorProp.l2BlockNumber, 1000);
        assertEq(anchorProp.rootClaim, bytes32(uint256(100)));
        
        // Test getAnchorRoot
        (bytes32 root, uint128 blockNum) = rollup.getAnchorRoot();
        assertEq(root, bytes32(uint256(100)));
        assertEq(blockNum, 1000);
        
        // Test getProposalsLength
        assertEq(rollup.getProposalsLength(), 2); // Genesis + 1 proposal
        
        // Test latestProposals
        uint256[] memory latest = rollup.latestProposals(10);
        assertEq(latest.length, 2);
        assertEq(latest[0], 1); // Most recent first
        assertEq(latest[1], 0);
        
        // Test getProposals batch
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        Rollup.Proposal[] memory props = rollup.getProposals(ids);
        assertEq(props.length, 2);
        assertEq(props[0].l2BlockNumber, 1000);
        assertEq(props[1].l2BlockNumber, 1100);
        
        // Test isResolvable
        assertEq(rollup.isResolvable(id1), false); // Not yet
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        assertEq(rollup.isResolvable(id1), true); // Now resolvable
        
        // Test needsDefense
        assertEq(rollup.needsDefense(id1), false); // Not challenged
    }
    
    function testNeedsDefense() public {
        vm.prank(proposer);
        uint256 id = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        // Initially doesn't need defense
        assertEq(rollup.needsDefense(id), false);
        
        // Challenge it
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(id);
        
        // Now needs defense
        assertEq(rollup.needsDefense(id), true);
        
        // After proof, no longer needs defense
        vm.prank(prover);
        rollup.proveProposal(id, hex"00");
        assertEq(rollup.needsDefense(id), false);
        
        // After deadline, no longer needs defense
        vm.warp(block.timestamp + PROVE_DURATION + 1);
        assertEq(rollup.needsDefense(id), false);
    }
    
    function testOwnershipFunctions() public {
        // Test that only owner can set proposers
        vm.prank(address(0x999));
        vm.expectRevert("Ownable: caller is not the owner");
        rollup.setProposer(address(0x888), true);
        
        // Owner can set proposer
        rollup.setProposer(address(0x888), true);
        assertTrue(rollup.whitelistedProposer(address(0x888)));
        
        // Owner can remove proposer
        rollup.setProposer(address(0x888), false);
        assertFalse(rollup.whitelistedProposer(address(0x888)));
        
        // Test ownership transfer
        address newOwner = address(0x777);
        rollup.transferOwnership(newOwner);
        
        // After transfer, new owner can immediately set proposers
        vm.prank(newOwner);
        rollup.setProposer(address(0x666), true);
        assertTrue(rollup.whitelistedProposer(address(0x666)));
        
        // Old owner can't set proposers anymore
        vm.expectRevert("Ownable: caller is not the owner");
        rollup.setProposer(address(0x555), true);
    }
    
    function testComplexProposalChains() public {
        // Create a chain: genesis -> p1 -> p2 -> p3
        vm.prank(proposer);
        uint256 p1 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(100)),
            1100,
            0
        );
        
        // Resolve p1
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(p1);
        
        // Build p2 on p1
        vm.prank(proposer);
        uint256 p2 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1200,
            uint32(p1)
        );
        
        // Build p3 on p2 (before p2 is resolved)
        vm.prank(proposer);
        uint256 p3 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            1300,
            uint32(p2)
        );
        
        // Can't resolve p3 before p2
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        vm.expectRevert(Rollup.ParentGameNotResolved.selector);
        rollup.resolveProposal(p3);
        
        // Resolve p2
        rollup.resolveProposal(p2);
        
        // Now can resolve p3
        rollup.resolveProposal(p3);
        
        // Anchor should be at p3
        assertEq(rollup.anchorProposalId(), p3);
    }
    
    function testProposalAuthorizedFunction() public {
        // Test whitelisted proposer
        assertTrue(rollup.proposalAuthorized(proposer, 1100));
        
        // Test non-whitelisted with recent block
        assertFalse(rollup.proposalAuthorized(address(0x999), 1100));
        
        // Test non-whitelisted with old block
        // Block 1100 timestamp = 1000 + (100 * 2) = 1200
        // Need current time > 1200 + FALLBACK_TIMEOUT
        vm.warp(1200 + FALLBACK_TIMEOUT + 1);
        assertTrue(rollup.proposalAuthorized(address(0x999), 1100));
    }
    
    function testL2TimestampFunctions() public {
        // Test computeL2Timestamp
        assertEq(rollup.computeL2Timestamp(1000), 1000); // Genesis block
        assertEq(rollup.computeL2Timestamp(1100), 1200); // 1000 + (100 * 2)
        assertEq(rollup.computeL2Timestamp(2000), 3000); // 1000 + (1000 * 2)
        
        // Test l2BlockAge
        vm.warp(5000);
        assertEq(rollup.l2BlockAge(1000), 4000); // 5000 - 1000
        assertEq(rollup.l2BlockAge(1100), 3800); // 5000 - 1200
    }
    
    function testMultipleBranchesFromSameParent() public {
        // Enable second proposer
        address proposer2 = address(0x999);
        vm.deal(proposer2, 10 ether);
        rollup.setProposer(proposer2, true);
        
        // Both proposers create competing proposals from genesis
        // They propose the same L2 block number with different roots
        vm.prank(proposer);
        uint256 branch1 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(111)),
            1100,
            0
        );
        
        vm.prank(proposer2);
        uint256 branch2 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(222)),
            1100,
            0
        );
        
        // Both are valid proposals
        Rollup.Proposal memory p1 = rollup.getProposal(branch1);
        Rollup.Proposal memory p2 = rollup.getProposal(branch2);
        assertEq(p1.parentIndex, 0);
        assertEq(p2.parentIndex, 0);
        assertEq(p1.l2BlockNumber, 1100);
        assertEq(p2.l2BlockNumber, 1100);
        
        // Resolve first branch
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(branch1);
        assertEq(rollup.anchorProposalId(), branch1);
        
        // Resolve second branch
        rollup.resolveProposal(branch2);
        // Anchor should NOT update because branch2 has the same block number as branch1
        // The contract only updates anchor if new block number > current anchor block number
        assertEq(rollup.anchorProposalId(), branch1);
    }
    
    function testGameOverEdgeCases() public {
        vm.prank(proposer);
        uint256 id = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        // Not over initially
        assertFalse(rollup.gameOver(id));
        
        // Exactly at deadline - still not over
        vm.warp(block.timestamp + CHALLENGE_DURATION);
        assertFalse(rollup.gameOver(id));
        
        // One second after deadline - now over
        vm.warp(block.timestamp + 1);
        assertTrue(rollup.gameOver(id));
        
        // Also over if proven
        vm.prank(proposer);
        uint256 id2 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            1200,
            1
        );
        
        vm.prank(prover);
        rollup.proveProposal(id2, hex"00");
        assertTrue(rollup.gameOver(id2));
    }
    
    function testPermissionlessCatchUpBurst() public {
        // Scenario: chain is three intervals behind
        // First, advance time so blocks become old enough for permissionless submission
        // Block 1100 timestamp = 1000 + (100 * 2) = 1200
        // Block 1200 timestamp = 1000 + (200 * 2) = 1400
        // For permissionless, need: block.timestamp - l2Timestamp > FALLBACK_TIMEOUT
        // We want both blocks to be old enough, so use block 1200's timestamp
        vm.warp(1400 + FALLBACK_TIMEOUT + 1);
        
        // Non-whitelisted account
        address permissionlessUser = address(0x999);
        vm.deal(permissionlessUser, 10 * PROPOSER_BOND);
        
        // Submit two consecutive proposals in the same transaction batch
        vm.startPrank(permissionlessUser);
        
        // P1: advance from 1000 to 1100
        uint256 p1 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(100)),
            1100,
            0 // parent is genesis
        );
        
        // P2: advance from 1100 to 1200
        uint256 p2 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1200,
            uint32(p1) // parent is P1
        );
        
        vm.stopPrank();
        
        // Assert both succeed
        assertEq(p1, 1);
        assertEq(p2, 2);
        
        // Assert P2's parentIndex == P1
        Rollup.Proposal memory proposal2 = rollup.getProposal(p2);
        assertEq(proposal2.parentIndex, p1);
    }
    
    function testRejectRetroProposalsByPermissionlessUser() public {
        // Warp so that block 1100 is old enough for permissionless submission
        vm.warp(1200 + FALLBACK_TIMEOUT + 1);
        
        // Non-whitelisted account
        address permissionlessUser = address(0x999);
        vm.deal(permissionlessUser, PROPOSER_BOND);
        
        // Try to submit block 1050 which is > genesis (1000) but would go backwards
        // This should fail with BadCadence because 1050 != 1000 + PROPOSAL_INTERVAL
        vm.prank(permissionlessUser);
        vm.expectRevert(Rollup.BadCadence.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(100)),
            1050, // Not on the interval
            0
        );
        
        // Also try block 900 which is < anchor
        vm.prank(permissionlessUser);
        vm.expectRevert(Rollup.BadCadence.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(100)),
            900, // Less than anchor
            0
        );
    }
    
    
    function testAnchorAdvanceOnlyWhenL2BlockNumberIncreases() public {
        // Create first proposal
        vm.prank(proposer);
        uint256 p1 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(111)),
            1100,
            0
        );
        
        // Create second proposal with same block number but different root
        vm.prank(proposer);
        uint256 p2 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(222)),
            1100,
            0
        );
        
        // Resolve first proposal - anchor should update
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(p1);
        assertEq(rollup.anchorProposalId(), p1);
        
        // Get anchor block number
        (, uint128 anchorBlockNum) = rollup.getAnchorRoot();
        assertEq(anchorBlockNum, 1100);
        
        // Resolve second proposal - anchor should NOT update
        rollup.resolveProposal(p2);
        assertEq(rollup.anchorProposalId(), p1); // Still p1
        
        // Verify anchor block number hasn't changed
        (, uint128 newAnchorBlockNum) = rollup.getAnchorRoot();
        assertEq(newAnchorBlockNum, 1100);
    }
    
    function testPermissionlessWindowClosesAutomatically() public {
        // First, make blocks old enough for permissionless submission
        // We need blocks 1100, 1200, and 1300 to be old
        // Block 1300 timestamp = 1000 + (300 * 2) = 1600
        vm.warp(1600 + FALLBACK_TIMEOUT + 1);
        
        address permissionlessUser = address(0x999);
        vm.deal(permissionlessUser, 10 * PROPOSER_BOND);
        
        // Permissionless burst to catch up
        vm.startPrank(permissionlessUser);
        
        // Submit proposals to catch up from 1000 to 1300
        uint256 p1 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(100)),
            1100,
            0
        );
        
        uint256 p2 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1200,
            uint32(p1)
        );
        
        uint256 p3 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            1300,
            uint32(p2)
        );
        
        // Now try to submit block 1400
        // Block 1400 timestamp = 1000 + (400 * 2) = 1800
        // Current time = 1200 + FALLBACK_TIMEOUT + 1
        // Age of block 1400 = current_time - 1800
        
        // Let's calculate when block 1400 would NOT be old enough
        // We need: l2BlockAge(1400) <= FALLBACK_TIMEOUT
        // So: block.timestamp - 1800 <= FALLBACK_TIMEOUT
        // So: block.timestamp <= 1800 + FALLBACK_TIMEOUT
        
        // Set time so block 1400 is NOT old enough
        vm.warp(1800 + FALLBACK_TIMEOUT - 100); // 100 seconds before it would be allowed
        
        // This should revert with BadAuth because the block isn't old enough
        vm.expectRevert(Rollup.BadAuth.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(400)),
            1400,
            uint32(p3)
        );
        
        vm.stopPrank();
        
        // Verify that whitelisted proposers can still propose
        vm.prank(proposer);
        uint256 p4 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(400)),
            1400,
            uint32(p3)
        );
        assertGt(p4, 0);
    }
    
    function testProposerProvesOwnChallengedProposal() public {
        // Proposer submits
        vm.prank(proposer);
        uint256 id = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1100,
            0
        );
        
        // Challenger challenges
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(id);
        
        // Proposer proves their own proposal
        vm.prank(proposer);
        rollup.proveProposal(id, hex"00");
        
        // Resolve
        vm.warp(block.timestamp + PROVE_DURATION + 1);
        rollup.resolveProposal(id);
        
        // Check credits - proposer gets all bonds
        assertEq(rollup.credit(proposer), PROPOSER_BOND + CHALLENGER_BOND);
        assertEq(rollup.credit(challenger), 0);
    }
    
    function testDoubleChallengeReverts() public {
        vm.prank(proposer);
        uint256 id = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(1)),
            1100,
            0
        );
        
        // First challenge succeeds
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(id);
        
        // Second challenge should revert
        address secondChallenger = address(0xdead);
        vm.deal(secondChallenger, CHALLENGER_BOND);
        vm.expectRevert(Rollup.AlreadyChallenged.selector);
        vm.prank(secondChallenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(id);
    }
    
    function testChallengeAfterProofFails() public {
        vm.prank(proposer);
        uint256 id = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(1)),
            1100,
            0
        );
        
        // Prove the proposal
        vm.prank(prover);
        rollup.proveProposal(id, hex"00");
        
        // Challenge should fail because game is over
        vm.expectRevert(Rollup.GameNotOver.selector);
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(id);
    }
    
    function testBondBurnWhenParentInvalid() public {
        // First create a valid proposal from genesis
        vm.prank(proposer);
        uint256 validId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(1)),
            1100,
            0
        );
        
        // Create a child that will be invalidated
        vm.prank(proposer);
        uint256 childId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(2)),
            1200,
            uint32(validId)
        );
        
        // Challenge the parent and let challenger win
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(validId);
        vm.warp(block.timestamp + PROVE_DURATION + 1);
        rollup.resolveProposal(validId);
        
        // Resolve the child - it inherits parent's CHALLENGER_WINS status
        // Since it wasn't challenged, the bond is burned
        rollup.resolveProposal(childId);
        
        // Verify bond was burned
        Rollup.Proposal memory child = rollup.getProposal(childId);
        assertEq(uint256(child.resolutionStatus), uint256(Rollup.ResolutionStatus.CHALLENGER_WINS));
        assertEq(child.challenger, address(0)); // No challenger
        assertEq(rollup.credit(address(0)), PROPOSER_BOND); // Bond goes to address(0)
    }
    
    function testReentrancyProtectionSuccessPath() public {
        // Setup: proposer wins and has credit
        vm.prank(proposer);
        uint256 id = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(1)),
            1100,
            0
        );
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(id);
        
        // Create a normal claimer (not re-entrant)
        address normalClaimer = proposer;
        uint256 balanceBefore = normalClaimer.balance;
        
        // Claim should succeed
        vm.prank(normalClaimer);
        rollup.claimCredit(normalClaimer);
        
        // Verify credit was withdrawn
        assertEq(rollup.credit(normalClaimer), 0);
        assertEq(normalClaimer.balance, balanceBefore + PROPOSER_BOND);
    }
    
    function testWildcardProposerToggle() public {
        // Fund the non-whitelisted address
        address nonWhitelisted = address(0x999);
        vm.deal(nonWhitelisted, 10 * PROPOSER_BOND);
        
        // Initially, only whitelisted proposer can propose
        vm.expectRevert(Rollup.BadAuth.selector);
        vm.prank(nonWhitelisted);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(1)),
            1100,
            0
        );
        
        // Enable wildcard (permissionless mode)
        rollup.setProposer(address(0), true);
        
        // Now anyone can propose
        vm.prank(nonWhitelisted);
        uint256 id1 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(1)),
            1100,
            0
        );
        assertGt(id1, 0);
        
        // Disable wildcard
        rollup.setProposer(address(0), false);
        
        // Non-whitelisted should fail again
        vm.expectRevert(Rollup.BadAuth.selector);
        vm.prank(nonWhitelisted);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(2)),
            1200,
            uint32(id1)
        );
        
        // But whitelisted proposer still works
        vm.prank(proposer);
        uint256 id2 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(2)),
            1200,
            uint32(id1)
        );
        assertGt(id2, 0);
    }
}
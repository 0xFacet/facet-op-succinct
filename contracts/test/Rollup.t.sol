// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Rollup, AggregationOutputs} from "../src/Rollup.sol";
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
    
    bytes32 constant ROLLUP_CONFIG_HASH = bytes32(uint256(1));
    bytes32 constant AGGREGATION_VKEY = bytes32(uint256(2));
    bytes32 constant RANGE_VKEY_COMMITMENT = bytes32(uint256(3));
    
    function setUp() public {
        // Set up realistic block environment
        vm.roll(100); // Set block number to 100
        vm.warp(1000); // Set block timestamp to 1000
        
        verifier = new MockSP1Verifier();
        
        rollup = new Rollup(
            CHALLENGE_DURATION,
            PROVE_DURATION,
            CHALLENGER_BOND,
            PROPOSER_BOND,
            FALLBACK_TIMEOUT,
            bytes32(uint256(100)), // start root
            1000, // start block
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
            2000
        );
        
        assertEq(proposalId, 1); // 0 is genesis
        
        Rollup.Proposal memory proposal = rollup.getProposal(proposalId);
        assertEq(proposal.proposer, proposer);
        assertEq(proposal.rootClaim, bytes32(uint256(200)));
        assertEq(proposal.l2BlockNumber, 2000);
        assertEq(uint8(proposal.proposalStatus), uint8(Rollup.ProposalStatus.Unchallenged));
    }
    
    function testChallengeProposal() public {
        // Submit proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
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
            2000
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
            2000
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
            2000
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
            2000
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
        vm.deal(nonWhitelisted, 2 * PROPOSER_BOND); // Fund the account first
        
        vm.prank(nonWhitelisted);
        vm.expectRevert(Rollup.BadAuth.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(bytes32(uint256(200)), 2000);
        
        // Wait for fallback timeout
        vm.warp(block.timestamp + FALLBACK_TIMEOUT + 1);
        
        // Now anyone can propose
        vm.prank(nonWhitelisted);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
        );
        
        assertEq(proposalId, 1); // 0 is genesis
    }
    
    function testProveUnchallengedProposal() public {
        // Submit proposal (unchallenged)
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
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
            2000
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
            2000
        );
        
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(id1);
        
        // Submit second proposal building on first
        vm.prank(proposer);
        uint256 id2 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            3000
        );
        
        Rollup.Proposal memory proposal2 = rollup.getProposal(id2);
        assertEq(proposal2.parentIndex, 1); // Should point to first proposal
    }
    
    function testSelfChallengeAllowed() public {
        // Proposer submits proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
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
        rollup.submitProposal{value: PROPOSER_BOND - 1}(bytes32(uint256(200)), 2000);
        
        vm.prank(proposer);
        vm.expectRevert(Rollup.IncorrectBondAmount.selector);
        rollup.submitProposal{value: PROPOSER_BOND + 1}(bytes32(uint256(200)), 2000);
        
        // Submit valid proposal for challenge test
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
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
            2000
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
            2000
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
            2000
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
            2000
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
        vm.expectRevert(Rollup.InvalidPhase.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            1000 // Same as genesis block
        );
        
        vm.prank(proposer);
        vm.expectRevert(Rollup.InvalidPhase.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            999 // Less than genesis block
        );
    }
    
    function testMultipleProposalsFromSameParent() public {
        address proposer2 = address(0x6);
        vm.deal(proposer2, 10 ether);
        rollup.setProposer(proposer2, true);
        
        // Create two proposals from the same parent (genesis)
        vm.prank(proposer);
        uint256 proposalA = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
        );
        
        vm.prank(proposer2);
        uint256 proposalB = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            2100
        );
        
        // Both should have genesis as parent
        Rollup.Proposal memory propA = rollup.getProposal(proposalA);
        Rollup.Proposal memory propB = rollup.getProposal(proposalB);
        assertEq(propA.parentIndex, 0);
        assertEq(propB.parentIndex, 0);
        
        // Scenario 1: Proposal A wins (unchallenged)
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(proposalA);
        
        // Proposal A becomes the new anchor
        assertEq(rollup.anchorProposalId(), proposalA);
        
        // What happens to Proposal B? It should be obsolete but let's see...
        // Try to resolve proposal B
        rollup.resolveProposal(proposalB);
        
        // Check if B overwrites the anchor (it should since obsolete proposals can update anchor)
        assertEq(rollup.anchorProposalId(), proposalB, "Obsolete proposal should update anchor");
        
        // Both proposers get their bonds back (obsolete proposals still get bonds)
        assertEq(rollup.credit(proposer), PROPOSER_BOND);
        assertEq(rollup.credit(proposer2), PROPOSER_BOND);
    }
    
    function testMultipleProposalsFromSameParentWithChallenge() public {
        address proposer2 = address(0x6);
        address challenger2 = address(0x7);
        vm.deal(proposer2, 10 ether);
        vm.deal(challenger2, 10 ether);
        rollup.setProposer(proposer2, true);
        
        // Create two proposals from the same parent (genesis)
        vm.prank(proposer);
        uint256 proposalA = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
        );
        
        vm.prank(proposer2);
        uint256 proposalB = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            2100
        );
        
        // Challenge proposal A
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(proposalA);
        
        // Wait for prove deadline to pass (challenger wins)
        vm.warp(block.timestamp + PROVE_DURATION + 1);
        rollup.resolveProposal(proposalA);
        
        // Proposal A should be CHALLENGER_WINS, anchor unchanged
        Rollup.Proposal memory propA = rollup.getProposal(proposalA);
        assertEq(uint8(propA.resolutionStatus), uint8(Rollup.ResolutionStatus.CHALLENGER_WINS));
        assertEq(rollup.anchorProposalId(), 0); // Still genesis
        
        // Proposal B should still be valid and resolvable
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(proposalB);
        
        // Proposal B should now be the anchor
        assertEq(rollup.anchorProposalId(), proposalB);
        
        // Check credits
        assertEq(rollup.credit(challenger), PROPOSER_BOND + CHALLENGER_BOND);
        assertEq(rollup.credit(proposer2), PROPOSER_BOND);
    }
    
    function testRaceConditionMultipleProposals() public {
        address proposer2 = address(0x6);
        address proposer3 = address(0x7);
        vm.deal(proposer2, 10 ether);
        vm.deal(proposer3, 10 ether);
        rollup.setProposer(proposer2, true);
        rollup.setProposer(proposer3, true);
        
        // Three proposals all building on genesis
        vm.prank(proposer);
        uint256 propA = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(100)),
            1500
        );
        
        vm.prank(proposer2);
        uint256 propB = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
        );
        
        vm.prank(proposer3);
        uint256 propC = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            2500
        );
        
        // Resolve B first (middle block number)
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(propB);
        assertEq(rollup.anchorProposalId(), propB);
        
        // Try to resolve A (lower block number) - should succeed but not update anchor
        rollup.resolveProposal(propA);
        assertEq(rollup.anchorProposalId(), propB, "Should not downgrade to lower block");
        
        // Try to resolve C (higher block number) - obsolete proposals can update anchor
        rollup.resolveProposal(propC);
        assertEq(rollup.anchorProposalId(), propC, "Obsolete proposal should update anchor");
        
        // Check credits - all proposers get their bonds back
        assertEq(rollup.credit(proposer), PROPOSER_BOND);
        assertEq(rollup.credit(proposer2), PROPOSER_BOND);
        assertEq(rollup.credit(proposer3), PROPOSER_BOND);
    }
    
    function testObsoleteProposalWithProof() public {
        address proposer2 = address(0x6);
        vm.deal(proposer2, 10 ether);
        rollup.setProposer(proposer2, true);
        
        // Create two proposals from the same parent
        vm.prank(proposer);
        uint256 proposalA = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
        );
        
        vm.prank(proposer2);
        uint256 proposalB = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            2100
        );
        
        // Challenge proposal B
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(proposalB);
        
        // Prove proposal B
        vm.prank(proposer2);
        rollup.proveProposal(proposalB, hex"00");
        
        // Meanwhile, proposal A resolves and becomes anchor
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(proposalA);
        assertEq(rollup.anchorProposalId(), proposalA);
        
        // Now resolve proposal B (which has been proven but is now obsolete)
        rollup.resolveProposal(proposalB);
        
        // B should become anchor since obsolete proposals can update anchor
        assertEq(rollup.anchorProposalId(), proposalB, "Obsolete proven proposal should update anchor");
        
        // Check credits - proposer2 gets full bonds back (proven their proposal)
        assertEq(rollup.credit(proposer), PROPOSER_BOND);
        assertEq(rollup.credit(proposer2), PROPOSER_BOND + CHALLENGER_BOND, "Proven proposal gets all bonds");
        assertEq(rollup.credit(challenger), 0, "Challenger loses bond when proposal is proven");
    }
    
    function testDoubleBranchRace() public {
        address proposer2 = address(0x6);
        address proposer3 = address(0x7);
        vm.deal(proposer2, 10 ether);
        vm.deal(proposer3, 10 ether);
        rollup.setProposer(proposer2, true);
        rollup.setProposer(proposer3, true);
        
        // Create proposal A at L2 #2000
        vm.prank(proposer);
        uint256 proposalA = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
        );
        
        // Create proposal B at L2 #2100 (while A is still unresolved)
        vm.prank(proposer2);
        uint256 proposalB = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            2100
        );
        
        // Create proposal C at L2 #2050 (between A and B, while both are unresolved)
        vm.prank(proposer3);
        uint256 proposalC = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(250)),
            2050
        );
        
        // Wait for challenge period to pass
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        
        // Now resolve A first
        rollup.resolveProposal(proposalA);
        assertEq(rollup.anchorProposalId(), proposalA, "A should be anchor");
        
        // Then resolve B
        rollup.resolveProposal(proposalB);
        assertEq(rollup.anchorProposalId(), proposalB, "B should be anchor");
        
        // Finally resolve C
        rollup.resolveProposal(proposalC);
        
        // C should NOT overwrite B as anchor since B has a higher block number
        assertEq(rollup.anchorProposalId(), proposalB, "C should NOT overwrite B as anchor");
        
        // Check proposal statuses
        Rollup.Proposal memory propA = rollup.getProposal(proposalA);
        Rollup.Proposal memory propB = rollup.getProposal(proposalB);
        Rollup.Proposal memory propC = rollup.getProposal(proposalC);
        
        assertEq(uint8(propA.proposalStatus), uint8(Rollup.ProposalStatus.Resolved));
        assertEq(uint8(propB.proposalStatus), uint8(Rollup.ProposalStatus.Resolved));
        assertEq(uint8(propC.proposalStatus), uint8(Rollup.ProposalStatus.Resolved));
        
        assertEq(uint8(propA.resolutionStatus), uint8(Rollup.ResolutionStatus.DEFENDER_WINS));
        assertEq(uint8(propB.resolutionStatus), uint8(Rollup.ResolutionStatus.DEFENDER_WINS));
        assertEq(uint8(propC.resolutionStatus), uint8(Rollup.ResolutionStatus.DEFENDER_WINS));
        
        // All proposers should get their bonds back
        assertEq(rollup.credit(proposer), PROPOSER_BOND);
        assertEq(rollup.credit(proposer2), PROPOSER_BOND);
        assertEq(rollup.credit(proposer3), PROPOSER_BOND);
    }
    
    function testProposalWithSameBlockNumberAsAnchor() public {
        // Submit and resolve first proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
        );
        
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(proposalId);
        
        // Try to submit proposal with same block number as anchor
        vm.prank(proposer);
        vm.expectRevert(Rollup.InvalidPhase.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            2000 // Same as anchor
        );
    }
    
    function testChallengeAtExactDeadline() public {
        // Submit proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
        );
        
        // Get the proposal to check deadline
        Rollup.Proposal memory prop = rollup.getProposal(proposalId);
        
        // Warp to exactly the deadline
        vm.warp(prop.deadline);
        
        // Should still be able to challenge at exact deadline
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(proposalId);
        
        // Verify challenge was successful
        prop = rollup.getProposal(proposalId);
        assertEq(prop.challenger, challenger);
        assertEq(uint8(prop.proposalStatus), uint8(Rollup.ProposalStatus.Challenged));
    }
    
    function testProveAlreadyResolvedProposal() public {
        // Submit proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
        );
        
        // Wait and resolve
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(proposalId);
        
        // Try to prove already resolved proposal
        vm.prank(prover);
        vm.expectRevert(Rollup.GameNotOver.selector);
        rollup.proveProposal(proposalId, hex"00");
    }
    
    function testReentrancyInClaimCredit() public {
        // Create reentrant contract
        ReentrantClaimer attacker = new ReentrantClaimer(rollup);
        rollup.setProposer(address(attacker), true);
        
        // Submit proposal as attacker
        vm.deal(address(attacker), PROPOSER_BOND);
        vm.prank(address(attacker));
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
        );
        
        // Resolve to give attacker credit
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(proposalId);
        
        // Check initial credit
        assertEq(rollup.credit(address(attacker)), PROPOSER_BOND);
        
        // Attempt reentrancy attack - should fail with TransferFailed
        // The credit is zeroed before transfer, so reentrancy attempt gets NoCredit error
        // but the main transfer still fails, resulting in TransferFailed
        vm.expectRevert(Rollup.TransferFailed.selector);
        attacker.claim();
        
        // IMPORTANT: Credit is NOT zero because the transaction reverted!
        // When transfer fails, the entire transaction reverts including the credit[recipient] = 0
        assertEq(rollup.credit(address(attacker)), PROPOSER_BOND);
        
        // Attacker should not have received any funds (reentrancy prevented)
        assertEq(address(attacker).balance, 0);
        
        // This shows that while reentrancy is prevented, failed transfers don't burn credit
        // This could be considered a feature (retry-able claims) or a bug depending on intent
    }
    
    function testMultipleProposalsResolvingInSameBlock() public {
        address proposer2 = address(0x6);
        address proposer3 = address(0x7);
        vm.deal(proposer2, 10 ether);
        vm.deal(proposer3, 10 ether);
        rollup.setProposer(proposer2, true);
        rollup.setProposer(proposer3, true);
        
        // Submit three proposals
        vm.prank(proposer);
        uint256 prop1 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(100)),
            1500
        );
        
        vm.prank(proposer2);
        uint256 prop2 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
        );
        
        vm.prank(proposer3);
        uint256 prop3 = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            2500
        );
        
        // Wait for challenge period
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        
        // Resolve all in same block
        rollup.resolveProposal(prop1);
        rollup.resolveProposal(prop2);
        rollup.resolveProposal(prop3);
        
        // Check final state - highest block number should be anchor
        assertEq(rollup.anchorProposalId(), prop3);
        
        // All should get credits
        assertEq(rollup.credit(proposer), PROPOSER_BOND);
        assertEq(rollup.credit(proposer2), PROPOSER_BOND);
        assertEq(rollup.credit(proposer3), PROPOSER_BOND);
    }
    
    function testProofSubmissionAtExactDeadline() public {
        // Submit and challenge proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
        );
        
        vm.prank(challenger);
        rollup.challengeProposal{value: CHALLENGER_BOND}(proposalId);
        
        // Get updated proposal with prove deadline
        Rollup.Proposal memory prop = rollup.getProposal(proposalId);
        
        // Warp to exactly the prove deadline
        vm.warp(prop.deadline);
        
        // Should still be able to prove at exact deadline
        vm.prank(prover);
        rollup.proveProposal(proposalId, hex"00");
        
        // Verify proof was accepted
        prop = rollup.getProposal(proposalId);
        assertEq(prop.prover, prover);
        assertEq(uint8(prop.proposalStatus), uint8(Rollup.ProposalStatus.ChallengedAndValidProofProvided));
    }
    
    function testOwnerRemovingProposerMidProposal() public {
        // Submit proposal
        vm.prank(proposer);
        uint256 proposalId = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
        );
        
        // Owner removes proposer permission
        rollup.setProposer(proposer, false);
        
        // Proposal should still be resolvable
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(proposalId);
        
        // Proposer should still get their bond back
        assertEq(rollup.credit(proposer), PROPOSER_BOND);
        
        // But proposer can't submit new proposals
        vm.prank(proposer);
        vm.expectRevert(Rollup.BadAuth.selector);
        rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            3000
        );
    }
    
    function testProposalParentChainValidation() public {
        address proposer2 = address(0x6);
        vm.deal(proposer2, 10 ether);
        rollup.setProposer(proposer2, true);
        
        // Create proposal A from genesis
        vm.prank(proposer);
        uint256 propA = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(100)),
            1500
        );
        
        // Create proposal B from genesis (not from A)
        vm.prank(proposer2);
        uint256 propB = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(200)),
            2000
        );
        
        // Verify both have genesis as parent
        Rollup.Proposal memory proposalA = rollup.getProposal(propA);
        Rollup.Proposal memory proposalB = rollup.getProposal(propB);
        assertEq(proposalA.parentIndex, 0);
        assertEq(proposalB.parentIndex, 0);
        
        // Resolve A
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        rollup.resolveProposal(propA);
        assertEq(rollup.anchorProposalId(), propA);
        
        // New proposal should now build on A
        vm.prank(proposer);
        uint256 propC = rollup.submitProposal{value: PROPOSER_BOND}(
            bytes32(uint256(300)),
            3000
        );
        
        Rollup.Proposal memory proposalC = rollup.getProposal(propC);
        assertEq(proposalC.parentIndex, propA);
    }
    
    function testClaimingCreditsFromMultipleProofs() public {
        address multiProver = address(0x8);
        vm.deal(multiProver, 10 ether);
        
        // Create 3 proposals from different proposers
        address[] memory proposers = new address[](3);
        proposers[0] = address(0x10);
        proposers[1] = address(0x11);
        proposers[2] = address(0x12);
        
        uint256[] memory proposalIds = new uint256[](3);
        
        for (uint i = 0; i < 3; i++) {
            vm.deal(proposers[i], 10 ether);
            rollup.setProposer(proposers[i], true);
            
            vm.prank(proposers[i]);
            proposalIds[i] = rollup.submitProposal{value: PROPOSER_BOND}(
                bytes32(uint256((i + 1) * 100)),
                2000 + uint128(i * 100)
            );
            
            // Challenge each proposal
            vm.prank(challenger);
            rollup.challengeProposal{value: CHALLENGER_BOND}(proposalIds[i]);
            
            // MultiProver proves each one
            vm.prank(multiProver);
            rollup.proveProposal(proposalIds[i], hex"00");
        }
        
        // Resolve all proposals
        for (uint i = 0; i < 3; i++) {
            rollup.resolveProposal(proposalIds[i]);
        }
        
        // MultiProver should have 3x challenger bonds
        uint256 expectedCredit = CHALLENGER_BOND * 3;
        assertEq(rollup.credit(multiProver), expectedCredit);
        
        // Claim all credits at once
        uint256 balanceBefore = multiProver.balance;
        vm.prank(multiProver);
        rollup.claimCredit(multiProver);
        
        // Verify all credits claimed
        assertEq(multiProver.balance, balanceBefore + expectedCredit);
        assertEq(rollup.credit(multiProver), 0);
        
        // Each proposer should have their bond back
        for (uint i = 0; i < 3; i++) {
            assertEq(rollup.credit(proposers[i]), PROPOSER_BOND);
        }
    }
}

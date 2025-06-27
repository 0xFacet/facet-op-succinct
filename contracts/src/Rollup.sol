// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ISP1Verifier } from "@sp1-contracts/src/ISP1Verifier.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

struct AggregationOutputs {
    bytes32 l1Head;
    bytes32 l2PreRoot;
    bytes32 claimRoot;
    uint256 claimBlockNum;
    bytes32 rollupConfigHash;
    bytes32 rangeVkeyCommitment;
    address proverAddress;
}

/// @title Rollup
/// @notice Single-contract fault-proof system: submit → challenge → prove → resolve.
contract Rollup is Ownable {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public immutable MAX_CHALLENGE_SECS;
    uint256 public immutable MAX_PROVE_SECS;
    uint256 public immutable CHALLENGER_BOND;
    uint256 public immutable PROPOSER_BOND;
    uint256 public immutable FALLBACK_TIMEOUT_SECS;

    ISP1Verifier public immutable VERIFIER;
    bytes32 public immutable ROLLUP_CONFIG_HASH;
    bytes32 public immutable AGG_VKEY;
    bytes32 public immutable RANGE_VKEY_COMMITMENT;

    string public constant version = "1.0.0";

    /*//////////////////////////////////////////////////////////////
                               ENUMS
    //////////////////////////////////////////////////////////////*/

    enum ResolutionStatus { IN_PROGRESS, DEFENDER_WINS, CHALLENGER_WINS }

    enum ProposalStatus {
        Unchallenged,
        Challenged,
        UnchallengedAndValidProofProvided,
        ChallengedAndValidProofProvided,
        Resolved
    }
    
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event ProposalSubmitted(uint256 indexed proposalId, address indexed proposer, bytes32 root, uint128 l2BlockNumber);
    event ProposalChallenged(uint256 indexed proposalId, address indexed challenger);
    event ProposalProven(uint256 indexed proposalId, address indexed prover);
    event ProposalResolved(uint256 indexed proposalId, ResolutionStatus status);
    event AnchorUpdated(uint256 indexed proposalId, bytes32 root, uint128 l2BlockNumber);
    event ProposalClosed(uint256 indexed proposalId);
    event ProposerPermissionUpdated(address indexed proposer, bool allowed);

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error BadAuth();
    error IncorrectBondAmount();
    error AlreadyChallenged();
    error GameNotOver();
    error GameOver();
    error InvalidPhase();
    error AlreadyResolved();
    error ParentNotResolved();
    error NotFinalized();
    error NoCredit();
    error TransferFailed();
    error InvalidProposalStatus();

    /*//////////////////////////////////////////////////////////////
                               STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Proposal {
        bytes32 rootClaim;
        bytes32 l1Head;
        uint128 l2BlockNumber;
        uint64 deadline;
        uint64 resolvedAt;
        address proposer;
        uint32 parentIndex;
        ProposalStatus proposalStatus;
        ResolutionStatus resolutionStatus;
        address challenger;
        address prover;
    }

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    Proposal[] proposals; // index == proposalId

    mapping(address => uint256) public credit;

    mapping(address => bool) public whitelistedProposer;
    uint256 public lastProposalTimestamp;

    uint32  public anchorProposalId; // index of proposal that is current anchor proposal

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        uint256 _challengeSecs,
        uint256 _proveSecs,
        uint256 _challengerBond,
        uint256 _proposerBond,
        uint256 _fallbackTimeout,
        bytes32 _startRoot,
        uint128 _startBlock,
        ISP1Verifier _verifier,
        bytes32 _rollupHash,
        bytes32 _aggVkey,
        bytes32 _rangeCommit
    ) {
        MAX_CHALLENGE_SECS    = _challengeSecs;
        MAX_PROVE_SECS        = _proveSecs;
        CHALLENGER_BOND       = _challengerBond;
        PROPOSER_BOND         = _proposerBond;
        FALLBACK_TIMEOUT_SECS = _fallbackTimeout;
        
        VERIFIER              = _verifier;
        ROLLUP_CONFIG_HASH    = _rollupHash;
        AGG_VKEY              = _aggVkey;
        RANGE_VKEY_COMMITMENT = _rangeCommit;

        anchorProposalId      = 0;
        
        lastProposalTimestamp = block.timestamp;

        // Create genesis proposal representing the starting anchor
        Proposal memory genesis = Proposal({
            l1Head: bytes32(0),
            rootClaim: _startRoot,
            l2BlockNumber: _startBlock,
            parentIndex: 0,
            deadline: 0,
            proposer: address(0),
            challenger: address(0),
            prover: address(0),
            resolvedAt: 0,
            proposalStatus: ProposalStatus.Resolved,
            resolutionStatus: ResolutionStatus.DEFENDER_WINS
        });
        
        proposals.push(genesis);
    }

    /*//////////////////////////////////////////////////////////////
                               ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new proposal advancing the canonical output root.
    /// @param root L2 output root being proposed.
    /// @param l2BlockNumber Corresponding L2 block number.
    /// @return proposalId Index of the created proposal.
    function submitProposal(
        bytes32 root,
        uint128 l2BlockNumber
    ) external payable returns (uint256 proposalId) {
        if (!allowedProposer(msg.sender)) revert BadAuth();
        if (msg.value != PROPOSER_BOND) revert IncorrectBondAmount();

        if (l2BlockNumber <= proposals[anchorProposalId].l2BlockNumber) revert InvalidPhase();

        lastProposalTimestamp = block.timestamp;

        proposals.push();
        proposalId = proposals.length - 1;
        
        Proposal storage p = proposals[proposalId];
        p.l1Head = blockhash(block.number - 5);
        p.rootClaim = root;
        p.l2BlockNumber = l2BlockNumber;
        p.parentIndex = anchorProposalId;
        p.deadline = uint64(block.timestamp + MAX_CHALLENGE_SECS);
        p.proposer = msg.sender;

        emit ProposalSubmitted(proposalId, msg.sender, root, l2BlockNumber);
    }

    function challengeProposal(uint256 id) external payable onlyIfGameNotOver(id) {
        Proposal storage p = proposals[id];
        if (p.proposalStatus != ProposalStatus.Unchallenged) revert AlreadyChallenged();
        if (msg.value != CHALLENGER_BOND) revert IncorrectBondAmount();

        p.challenger = msg.sender;
        p.proposalStatus = ProposalStatus.Challenged;
        p.deadline = uint64(block.timestamp + MAX_PROVE_SECS);

        emit ProposalChallenged(id, msg.sender);
    }

    function proveProposal(uint256 id, bytes calldata proof) external onlyIfGameNotOver(id) {
        Proposal storage p = proposals[id];

        AggregationOutputs memory pub = AggregationOutputs({
            l1Head: p.l1Head,
            l2PreRoot: proposals[p.parentIndex].rootClaim,
            claimRoot: p.rootClaim,
            claimBlockNum: p.l2BlockNumber,
            rollupConfigHash: ROLLUP_CONFIG_HASH,
            rangeVkeyCommitment: RANGE_VKEY_COMMITMENT,
            proverAddress: msg.sender
        });

        VERIFIER.verifyProof(AGG_VKEY, abi.encode(pub), proof);

        p.prover = msg.sender;
        p.proposalStatus = (p.challenger == address(0)) ?
            ProposalStatus.UnchallengedAndValidProofProvided :
            ProposalStatus.ChallengedAndValidProofProvided;

        emit ProposalProven(id, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                               RESOLUTION
    //////////////////////////////////////////////////////////////*/

    modifier onlyIfGameOver(uint256 proposalId) {
        if (!gameOver(proposalId)) revert GameOver();
        _;
    }
    
    modifier onlyIfGameNotOver(uint256 proposalId) {
        if (gameOver(proposalId)) revert GameNotOver();
        _;
    }

    function gameOver(uint256 proposalId) public view returns (bool) {
        Proposal storage p = proposals[proposalId];
        return p.deadline < block.timestamp || p.prover != address(0);
    }

    function resolveProposal(uint256 id) external onlyIfGameOver(id) {
        Proposal storage p = proposals[id];
        if (p.resolutionStatus != ResolutionStatus.IN_PROGRESS) revert AlreadyResolved();

        if (p.proposalStatus == ProposalStatus.Challenged) {
            // Challenger wins - no proof provided in time
            p.resolutionStatus = ResolutionStatus.CHALLENGER_WINS;
            credit[p.challenger] += PROPOSER_BOND + CHALLENGER_BOND;
        } else {
            // Defender wins - either unchallenged or proven
            p.resolutionStatus = ResolutionStatus.DEFENDER_WINS;

            if (p.proposalStatus == ProposalStatus.Unchallenged ||
                p.proposalStatus == ProposalStatus.UnchallengedAndValidProofProvided) {
                // Simple case: proposer gets their bond back
                credit[p.proposer] += PROPOSER_BOND;
            } else if (p.proposalStatus == ProposalStatus.ChallengedAndValidProofProvided) {
                uint256 totalBond = PROPOSER_BOND + CHALLENGER_BOND;
                
                if (p.prover == p.proposer) {
                    credit[p.prover] += totalBond;
                } else {
                    credit[p.prover] += CHALLENGER_BOND;
                    credit[p.proposer] += totalBond - CHALLENGER_BOND;
                }
            } else {
                revert InvalidProposalStatus();
            }
        }

        p.proposalStatus = ProposalStatus.Resolved;
        p.resolvedAt = uint64(block.timestamp);
        
        if (
            p.resolutionStatus == ResolutionStatus.DEFENDER_WINS && 
            p.l2BlockNumber > proposals[anchorProposalId].l2BlockNumber
        ) {
            anchorProposalId = uint32(id);
            emit AnchorUpdated(id, p.rootClaim, p.l2BlockNumber);
        }

        emit ProposalResolved(id, p.resolutionStatus);
        emit ProposalClosed(id);
    }

    /*//////////////////////////////////////////////////////////////
                         CREDIT WITHDRAWAL & FINALIZATION
    //////////////////////////////////////////////////////////////*/

    function claimCredit(address recipient) public {
        uint256 amount = credit[recipient];
        if (amount == 0) revert NoCredit();
        
        credit[recipient] = 0;
        (bool ok,) = recipient.call{ value: amount }("");
        if (!ok) revert TransferFailed();
    }
    
    /*//////////////////////////////////////////////////////////////
                           PROPOSER PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function setProposer(address proposer, bool allowed) external onlyOwner {
        whitelistedProposer[proposer] = allowed;
        emit ProposerPermissionUpdated(proposer, allowed);
    }

    function allowedProposer(address a) public view returns (bool) {
        return whitelistedProposer[a] ||
            whitelistedProposer[address(0)] ||
            (block.timestamp - lastProposalTimestamp > FALLBACK_TIMEOUT_SECS);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return proposals[id];
    }
    
    function getAnchorProposal() public view returns (Proposal memory) {
        return proposals[anchorProposalId];
    }
    
    function getAnchorRoot() public view returns (bytes32, uint128) {
        Proposal memory p = proposals[anchorProposalId];
        return (p.rootClaim, p.l2BlockNumber);
    }

    function getProposals(uint256[] calldata ids) external view returns (Proposal[] memory out) {
        out = new Proposal[](ids.length);
        for (uint256 i; i < ids.length; ++i) out[i] = proposals[ids[i]];
    }

    function latestProposals(uint256 count) external view returns (uint256[] memory ids) {
        uint256 total = proposals.length;
        if (count > total) count = total;
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) ids[i] = total - 1 - i;
    }

    function getProposalsLength() external view returns (uint256) {
        return proposals.length;
    }
    
    /// @notice Check if a proposal is resolvable (game over and not yet resolved)
    /// @param proposalId The proposal ID to check
    /// @return True if the proposal can be resolved
    function isResolvable(uint256 proposalId) external view returns (bool) {
        if (proposalId >= proposals.length) return false;
        Proposal storage p = proposals[proposalId];
        return gameOver(proposalId) && p.resolutionStatus == ResolutionStatus.IN_PROGRESS;
    }
    
    /// @notice Check if a proposal needs defending (challenged but not proven)
    /// @param proposalId The proposal ID to check
    /// @return True if the proposal is challenged and needs a proof
    function needsDefense(uint256 proposalId) external view returns (bool) {
        if (proposalId >= proposals.length) return false;
        return !gameOver(proposalId) && proposals[proposalId].proposalStatus == ProposalStatus.Challenged;
    }
}

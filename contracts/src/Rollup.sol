// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ISP1Verifier } from "@sp1-contracts/src/ISP1Verifier.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title Rollup
/// @notice Dual-track ZK fault validity proof system
/// @dev Supports two tracks:
/// @dev 1. Fault proofs: Optimistic proposals that can be challenged (low cost)
/// @dev 2. Validity proofs: Direct ZK proofs that bypass challenges (instant finality)
/// @dev 
/// @dev Key features:
/// @dev - Single-round dispute resolution.
/// @dev - Bulk invalidation: Validity proofs invalidate all conflicting fault proofs
/// @dev - Censorship resistance: Fallback window allows anyone to propose after timeout
contract Rollup is Ownable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public immutable MAX_CHALLENGE_SECS;
    uint256 public immutable MAX_PROVE_SECS;
    uint256 public immutable CHALLENGER_BOND;
    uint256 public immutable PROPOSER_BOND;
    uint256 public immutable FALLBACK_TIMEOUT_SECS;
    uint256 public immutable PROPOSAL_INTERVAL;
    uint256 public immutable L2_START_TIMESTAMP;
    uint256 public immutable L2_BLOCK_TIME;

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
        UnchallengedAndProven,
        ChallengedAndProven,
        Resolved
    }
    
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event ProposalSubmitted(uint256 indexed proposalId, uint256 indexed parentId, address indexed proposer, bytes32 root, uint128 l2BlockNumber);
    event ProposalChallenged(uint256 indexed proposalId, address indexed challenger);
    event ProposalProven(uint256 indexed proposalId, address indexed prover);
    event ProposalResolved(uint256 indexed proposalId, ResolutionStatus status);
    event AnchorUpdated(uint256 indexed proposalId, bytes32 root, uint128 l2BlockNumber);
    event ProposalClosed(uint256 indexed proposalId);
    event ProposerPermissionUpdated(address indexed proposer, bool allowed);
    event BlockProven(uint128 indexed l2BlockNumber, bytes32 root, address indexed prover);

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error BadAuth();
    error IncorrectBondAmount();
    error AlreadyChallenged();
    error GameNotOver();
    error GameOver();
    error AlreadyResolved();
    error NoCredit();
    error TransferFailed();
    error InvalidParentGame();
    error BadCadence();
    error ParentGameNotResolved();
    error ProposingBackwards();
    error ProposingFutureBlock();
    error BlockAlreadyProven();
    error L1BlockHashNotAvailable();
    error L1BlockHashNotCheckpointed();
    error NoCanonicalProposal();

    /*//////////////////////////////////////////////////////////////
                               STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Proposal {
        bytes32 rootClaim;

        // packed slot
        address proposer;
        uint32  l2BlockNumber;
        uint32  parentIndex;
        uint32  deadline;

        uint64  resolvedAt;
        ProposalStatus proposalStatus;
        ResolutionStatus resolutionStatus;
        address challenger;
        address prover;  // Who proved this specific proposal
    }
    
    // No struct needed - just store the prover address directly
    
    struct AggregationOutputs {
        bytes32 l1Head;
        bytes32 l2PreRoot;
        bytes32 claimRoot;
        uint256 claimBlockNum;
        bytes32 rollupConfigHash;
        bytes32 rangeVkeyCommitment;
        address proverAddress;
    }

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    Proposal[] proposals; // index == proposalId

    mapping(address => uint256) public credit;

    mapping(address => bool) public whitelistedProposer;

    // The anchor tracks the latest accepted block
    uint128 public anchorL2BlockNumber;
    
    // Checkpointed L1 block hashes for proof verification
    mapping(uint256 => bytes32) public l1BlockHashes;

    // Maps L2 block number to the canonical proposal ID
    // 0 means no canonical proposal exists (uninitialized storage)
    // type(uint32).max means proposal 0 (genesis) is canonical
    uint32 private constant GENESIS_SENTINEL = type(uint32).max;
    mapping(uint256 => uint32) private _canonical;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        uint256 _challengeSecs,
        uint256 _proveSecs,
        uint256 _challengerBond,
        uint256 _proposerBond,
        uint256 _fallbackTimeout,
        uint256 _proposalInterval,
        bytes32 _startRoot,
        uint128 _startBlock,
        uint256 _l2StartTimestamp,
        uint256 _l2BlockTime,
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
        PROPOSAL_INTERVAL     = _proposalInterval;
        L2_START_TIMESTAMP    = _l2StartTimestamp;
        L2_BLOCK_TIME         = _l2BlockTime;
        
        VERIFIER              = _verifier;
        ROLLUP_CONFIG_HASH    = _rollupHash;
        AGG_VKEY              = _aggVkey;
        RANGE_VKEY_COMMITMENT = _rangeCommit;

        anchorL2BlockNumber = _startBlock;
        
        // Create genesis proposal representing the starting anchor
        Proposal memory genesis = Proposal({
            rootClaim: _startRoot,
            l2BlockNumber: uint32(_startBlock),
            parentIndex: 0,
            deadline: 0,
            proposer: address(0),
            challenger: address(0),
            resolvedAt: 0,
            proposalStatus: ProposalStatus.Resolved,
            resolutionStatus: ResolutionStatus.DEFENDER_WINS,
            prover: address(0)
        });
        
        proposals.push(genesis);

        _trySetCanonical(_startBlock, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a proposal with validation common to both fault proofs and validity proofs
    /// @param root L2 output root being proposed
    /// @param l2BlockNumber L2 block number (must be parentBlock + PROPOSAL_INTERVAL)
    /// @param parentId Parent proposal ID (must be valid and not invalidated)
    /// @param proposer Proposer address (address(0) for validity proofs, actual address for fault proofs)
    /// @return proposalId ID of the created proposal
    function _createProposal(
        bytes32 root,
        uint128 l2BlockNumber,
        uint32 parentId,
        address proposer
    ) internal returns (uint256 proposalId) {
        if (parentId >= proposals.length) revert InvalidParentGame();
        Proposal storage parent = proposals[parentId];
        
        if (l2BlockNumber <= anchorL2BlockNumber) revert ProposingBackwards();
        if (computeL2Timestamp(l2BlockNumber) >= block.timestamp) revert ProposingFutureBlock();
        
        if (_canonicalExistsFor(l2BlockNumber)) revert BlockAlreadyProven();
        
        // Proposals must follow the exact interval cadence from their parent
        if (l2BlockNumber != parent.l2BlockNumber + PROPOSAL_INTERVAL) {
            revert BadCadence();
        }
        
        // Cannot build on top of invalidated proposals
        if (parent.resolutionStatus == ResolutionStatus.CHALLENGER_WINS) {
            revert InvalidParentGame();
        }
        proposals.push();
        proposalId = proposals.length - 1;
        
        Proposal storage p = proposals[proposalId];
        p.rootClaim = root;
        p.l2BlockNumber = uint32(l2BlockNumber);
        p.parentIndex = parentId;
        p.deadline = uint32(block.timestamp + MAX_CHALLENGE_SECS);
        p.proposer = proposer;
        
        emit ProposalSubmitted(proposalId, parentId, proposer, root, l2BlockNumber);
    }

    /// @notice Submit a fault proof proposal that can be challenged
    /// @param root Output root claim for the L2 block
    /// @param l2BlockNumber L2 block number being proposed
    /// @param parentId Parent proposal to build upon
    /// @return proposalId ID of created proposal
    /// @dev Requires PROPOSER_BOND and proposer must be whitelisted or in fallback window
    function submitProposal(
        bytes32 root,
        uint128 l2BlockNumber,
        uint32  parentId
    ) external payable returns (uint256 proposalId) {
        if (msg.value != PROPOSER_BOND) revert IncorrectBondAmount();
        
        // Authorization: whitelist OR 2-week fallback (censorship resistance)
        if (!isWhitelistedProposer(msg.sender) && !isInFallbackWindow(l2BlockNumber)) {
            revert BadAuth();
        }
        proposalId = _createProposal({
            root: root,
            l2BlockNumber: l2BlockNumber,
            parentId: parentId,
            proposer: msg.sender
        });
    }
    
    /// @notice Challenge a proposal claiming it has the wrong root
    /// @param id Proposal ID to challenge
    /// @dev Requires CHALLENGER_BOND, starts proof countdown
    function challengeProposal(uint256 id) external payable onlyIfGameNotOver(id) {
        if (msg.value != CHALLENGER_BOND) revert IncorrectBondAmount();
        
        Proposal storage p = proposals[id];
        if (p.proposalStatus != ProposalStatus.Unchallenged) revert AlreadyChallenged();

        p.challenger = msg.sender;
        p.proposalStatus = ProposalStatus.Challenged;
        p.deadline = uint32(block.timestamp + MAX_PROVE_SECS);

        emit ProposalChallenged(id, msg.sender);
    }

    /// @notice Submit a validity proof that bypasses the optimistic flow
    /// @param l2BlockNumber L2 block to prove (must be anchorBlock + PROPOSAL_INTERVAL)
    /// @param root Correct output root for this block
    /// @param l1BlockNumber L1 block used in proof (for L1 data availability)
    /// @param proof ZK proof of state transition from anchor to this block
    /// @dev Creates, proves, and resolves a proposal atomically. No bond required.
    function proveBlock(
        uint128 l2BlockNumber,
        bytes32 root,
        uint256 l1BlockNumber,
        bytes calldata proof
    ) external {
        // Validity proofs must build directly on the anchor to ensure linear progression
        // Anchor always has a canonical (genesis at minimum)
        uint32 parentProposalId = anchorProposalId();
        
        // address(0) proposer indicates no bond was collected
        uint256 proposalId = _createProposal({
            root: root,
            l2BlockNumber: l2BlockNumber,
            parentId: parentProposalId,
            proposer: address(0)
        });
        
        proveProposal(proposalId, l1BlockNumber, proof);
        resolveProposal(proposalId);
        
        emit BlockProven(l2BlockNumber, root, msg.sender);
    }

    /// @notice Submit ZK proof defending a proposal
    /// @param id Proposal to prove
    /// @param l1BlockNumber L1 block for data availability context
    /// @param proof ZK proof of state transition from parent to this proposal
    /// @dev Parent must be valid for proof to be useful, but that's checked in resolution
    function proveProposal(
        uint256 id, 
        uint256 l1BlockNumber,
        bytes calldata proof
    ) public onlyIfGameNotOver(id) {
        Proposal storage p = proposals[id];
        
        bytes32 parentRoot = proposals[p.parentIndex].rootClaim;
        bytes32 l1BlockHash = getL1BlockHash(l1BlockNumber);
        AggregationOutputs memory pub = AggregationOutputs({
            l1Head: l1BlockHash,
            l2PreRoot: parentRoot,
            claimRoot: p.rootClaim,
            claimBlockNum: p.l2BlockNumber,
            rollupConfigHash: ROLLUP_CONFIG_HASH,
            rangeVkeyCommitment: RANGE_VKEY_COMMITMENT,
            proverAddress: msg.sender
        });
        
        VERIFIER.verifyProof(AGG_VKEY, abi.encode(pub), proof);
        
        p.prover = msg.sender;
        p.proposalStatus = (p.proposalStatus == ProposalStatus.Challenged) 
            ? ProposalStatus.ChallengedAndProven 
            : ProposalStatus.UnchallengedAndProven;
        
        emit ProposalProven(id, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyIfGameOver(uint256 proposalId) {
        if (!gameOver(proposalId)) revert GameOver();
        _;
    }
    
    modifier onlyIfGameNotOver(uint256 proposalId) {
        if (gameOver(proposalId)) revert GameNotOver();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                          GAME STATE LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Check if a proposal's game has ended (ready for resolution)
    /// @param proposalId Proposal to check
    /// @return True if deadline passed, proven locally, or canonical exists for block
    function gameOver(uint256 proposalId) public view returns (bool) {
        Proposal storage p = proposals[proposalId];
        return p.deadline < block.timestamp || 
               p.prover != address(0) ||
               _canonicalExistsFor(p.l2BlockNumber);
    }

    /// @notice Calculate how long ago an L2 block should have been created
    /// @param l2BlockNumber L2 block number
    /// @return Age in seconds since the block's expected timestamp
    function l2BlockAge(uint256 l2BlockNumber) public view returns (uint256) {
        return block.timestamp - computeL2Timestamp(l2BlockNumber);
    }
    
    /// @notice Returns the L2 timestamp corresponding to a given L2 block number.
    /// @notice Compute the expected timestamp for an L2 block
    /// @param _l2BlockNumber L2 block number
    /// @return Expected timestamp based on L2_BLOCK_TIME and genesis
    function computeL2Timestamp(uint256 _l2BlockNumber) public view returns (uint256) {
        return L2_START_TIMESTAMP + ((_l2BlockNumber - proposals[0].l2BlockNumber) * L2_BLOCK_TIME);
    }
    
    /// @notice Get L1 block hash from checkpoint or EVM history
    /// @param l1BlockNumber L1 block number
    /// @return l1BlockHash Block hash (reverts if too old and not checkpointed)
    /// @dev Automatically caches recent block hashes for gas efficiency
    function getL1BlockHash(uint256 l1BlockNumber) internal returns (bytes32 l1BlockHash) {
        l1BlockHash = l1BlockHashes[l1BlockNumber];
        if (l1BlockHash == bytes32(0)) {
            // Only available for last 256 blocks
            l1BlockHash = blockhash(l1BlockNumber);
            if (l1BlockHash == bytes32(0)) {
                revert L1BlockHashNotCheckpointed();
            }
            l1BlockHashes[l1BlockNumber] = l1BlockHash;
        }
    }

    /// @notice Resolve a proposal determining if defender or challenger wins
    /// @param id Proposal to resolve
    /// @dev Resolution hierarchy:
    /// @dev 1. Parent invalid → challenger wins (cascading invalidation)
    /// @dev 2. Conflicts with canonical → challenger wins (bulk invalidation) 
    /// @dev 3. Has valid proof → defender wins
    /// @dev 4. Timeout: challenged → challenger wins, unchallenged → defender wins
    function resolveProposal(uint256 id) public onlyIfGameOver(id) {
        Proposal storage p = proposals[id];
        Proposal storage parent = proposals[p.parentIndex];
        
        if (parent.resolutionStatus == ResolutionStatus.IN_PROGRESS) {
            revert ParentGameNotResolved();
        }
        if (p.resolutionStatus != ResolutionStatus.IN_PROGRESS) {
            revert AlreadyResolved();
        }

        // Resolution hierarchy (order matters!)
        if (parent.resolutionStatus == ResolutionStatus.CHALLENGER_WINS) {
            p.resolutionStatus = ResolutionStatus.CHALLENGER_WINS;
        }
        else if (_proposalConflictsWithCanonical(p)) {
            p.resolutionStatus = ResolutionStatus.CHALLENGER_WINS;
        }
        else if (_getProposalProver(p) != address(0)) {
            p.resolutionStatus = ResolutionStatus.DEFENDER_WINS;
        }
        else if (p.proposalStatus == ProposalStatus.Challenged) {
            p.resolutionStatus = ResolutionStatus.CHALLENGER_WINS;
        } else {
            p.resolutionStatus = ResolutionStatus.DEFENDER_WINS;
        }
        
        if (p.resolutionStatus == ResolutionStatus.DEFENDER_WINS) {
            // Mark as canonical if not already set by validity proof
            _trySetCanonical(p.l2BlockNumber, uint32(id));
            
            // Advance anchor only if this directly extends it
            if (p.l2BlockNumber == anchorL2BlockNumber + PROPOSAL_INTERVAL) {
                anchorL2BlockNumber = p.l2BlockNumber;
                emit AnchorUpdated(id, p.rootClaim, p.l2BlockNumber);
            }
            
            _pay(p.proposer, _proposerBond(p));
            _pay(_getProposalProver(p), _challengerBond(p));
        } else if (p.resolutionStatus == ResolutionStatus.CHALLENGER_WINS) {
            address recipient = p.challenger;
            if (recipient == address(0)) {
                // Bulk invalidation case: pay canonical prover who proved correct root
                // If no canonical exists yet, bond is burned (recipient remains address(0))
                if (_canonicalExistsFor(p.l2BlockNumber)) {
                    recipient = _getProposalProver(_canonicalProposalFor(p.l2BlockNumber));
                }
            }
            _pay(recipient, _totalBond(p));
        }
        
        p.proposalStatus = ProposalStatus.Resolved;
        p.resolvedAt = uint64(block.timestamp);
        emit ProposalResolved(id, p.resolutionStatus);
        emit ProposalClosed(id);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL PAY-OUT HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Credits account
    function _pay(address to, uint256 amount) internal {
        if (to != address(0) && amount != 0) credit[to] += amount;
    }

    /// @dev Returns proposer bond amount (0 for validity proofs)
    function _proposerBond(Proposal storage p) internal view returns (uint256) {
        return p.proposer != address(0) ? PROPOSER_BOND : 0;
    }

    /// @dev Returns challenger bond amount (0 if unchallenged)
    function _challengerBond(Proposal storage p) internal view returns (uint256) {
        return p.challenger != address(0) ? CHALLENGER_BOND : 0;
    }

    /// @dev Total bonds at stake for this proposal
    function _totalBond(Proposal storage p) internal view returns (uint256) {
        return _proposerBond(p) + _challengerBond(p);
    }

    /// @dev Find who proved this proposal (considering canonical fallback)
    /// @return Prover address or address(0) if conflicts with canonical
    function _getProposalProver(Proposal storage p) internal view returns (address) {
        if (_proposalConflictsWithCanonical(p)) {
            return address(0);
        }
        
        // Prefer local prover, fall back to canonical proposal's prover
        if (p.prover != address(0)) {
            return p.prover;
        }
        
        if (_canonicalExistsFor(p.l2BlockNumber)) {
            Proposal storage canonical = _canonicalProposalFor(p.l2BlockNumber);
            return canonical.prover != address(0) ? canonical.prover : canonical.proposer;
        }
        
        return address(0);
    }
    
    /// @dev Check if proposal has wrong root compared to canonical
    function _proposalConflictsWithCanonical(Proposal storage p) internal view returns (bool) {
        return _canonicalExistsFor(p.l2BlockNumber) && 
               _canonicalProposalFor(p.l2BlockNumber).rootClaim != p.rootClaim;
    }


    /*//////////////////////////////////////////////////////////////
                         CREDIT WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw accumulated credit from bonds
    /// @param recipient Address to withdraw credit for
    /// @dev Uses pull pattern to prevent reentrancy
    function claimCredit(address recipient) public nonReentrant {
        uint256 amount = credit[recipient];
        if (amount == 0) revert NoCredit();
        
        credit[recipient] = 0;
        (bool ok,) = recipient.call{ value: amount }("");
        if (!ok) revert TransferFailed();
    }
    
    /*//////////////////////////////////////////////////////////////
                    PERMISSIONS & AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Update proposer whitelist
    /// @param proposer Address to update
    /// @param allowed Whether address can propose
    function setProposer(address proposer, bool allowed) external onlyOwner {
        whitelistedProposer[proposer] = allowed;
        emit ProposerPermissionUpdated(proposer, allowed);
    }

    /// @notice Check if address can submit proposals
    /// @param proposer Address to check
    /// @return True if whitelisted or wildcard enabled
    function isWhitelistedProposer(address proposer) public view returns (bool) {
        return whitelistedProposer[proposer] || whitelistedProposer[address(0)];
    }
    
    /// @notice Check if fallback window is active (anyone can propose)
    /// @param l2BlockNumber Block to check
    /// @return True if block is old enough for fallback
    function isInFallbackWindow(uint256 l2BlockNumber) public view returns (bool) {
        return l2BlockAge(l2BlockNumber) > FALLBACK_TIMEOUT_SECS;
    }

    /// @notice Store L1 block hash for proofs requiring old blocks
    /// @param l1BlockNumber L1 block to checkpoint (must be recent)
    /// @dev Only needed for blocks older than 256 blocks
    function checkpointL1BlockHash(uint256 l1BlockNumber) external {
        bytes32 blockHash = blockhash(l1BlockNumber);
        if (blockHash == bytes32(0)) {
            revert L1BlockHashNotAvailable();
        }
        l1BlockHashes[l1BlockNumber] = blockHash;
    }
    
    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the current anchor's output root
    /// @return Output root of the anchor block
    function anchorRoot() public view returns (bytes32) {
        // Anchor always has a canonical proposal (genesis at minimum)
        return _canonicalProposalFor(anchorL2BlockNumber).rootClaim;
    }

    /// @notice Get a single proposal
    /// @param id Proposal ID
    /// @return The proposal struct
    function getProposal(uint256 id) external view returns (Proposal memory) {
        return proposals[id];
    }
    
    /// @notice Get current anchor root and block number
    /// @return root Output root
    /// @return blockNumber L2 block number
    function getAnchorRoot() public view returns (bytes32, uint128) {
        return (anchorRoot(), anchorL2BlockNumber);
    }

    /// @notice Batch get proposals by IDs
    /// @param ids Array of proposal IDs
    /// @return out Array of proposals
    function getProposals(uint256[] calldata ids) external view returns (Proposal[] memory out) {
        out = new Proposal[](ids.length);
        for (uint256 i; i < ids.length; ++i) out[i] = proposals[ids[i]];
    }

    /// @notice Get most recent proposal IDs
    /// @param count Number of proposals to return
    /// @return ids Array of proposal IDs (newest first)
    function latestProposals(uint256 count) external view returns (uint256[] memory ids) {
        uint256 total = proposals.length;
        if (count > total) count = total;
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) ids[i] = total - 1 - i;
    }

    /// @notice Get total number of proposals
    /// @return Number of proposals created
    function getProposalsLength() external view returns (uint256) {
        return proposals.length;
    }
    
    /// @notice Check if proposal can be resolved
    /// @param proposalId Proposal to check
    /// @return True if game over and not yet resolved
    function isResolvable(uint256 proposalId) external view returns (bool) {
        if (proposalId >= proposals.length) return false;
        Proposal storage p = proposals[proposalId];
        return gameOver(proposalId) && p.resolutionStatus == ResolutionStatus.IN_PROGRESS;
    }
    
    /// @notice Check if proposal needs a proof
    /// @param proposalId Proposal to check  
    /// @return True if challenged and deadline not passed
    function needsDefense(uint256 proposalId) external view returns (bool) {
        if (proposalId >= proposals.length) return false;
        return !gameOver(proposalId) && proposals[proposalId].proposalStatus == ProposalStatus.Challenged;
    }
    
    /// @notice Get the canonical proposal ID for the anchor block
    /// @return Proposal ID of current anchor
    function anchorProposalId() public view returns (uint32) {
        return canonicalProposalIdFor(anchorL2BlockNumber);
    }

    /*//////////////////////////////////////////////////////////////
                     CANONICAL PROPOSAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the canonical proposal for an L2 block
    /// @param l2BlockNumber The L2 block number
    /// @return The canonical proposal, or empty proposal if none exists
    function canonicalProposalFor(uint256 l2BlockNumber) public view returns (Proposal memory) {
        if (!_canonicalExistsFor(l2BlockNumber)) revert NoCanonicalProposal();
        
        uint32 canonicalId = canonicalProposalIdFor(l2BlockNumber);
        return proposals[canonicalId];
    }

    /// @notice Get the canonical proposal ID for an L2 block
    /// @param l2BlockNumber The L2 block number
    /// @return The canonical proposal ID, or 0 if none exists
    function canonicalProposalIdFor(uint256 l2BlockNumber) public view returns (uint32) {
        if (!_canonicalExistsFor(l2BlockNumber)) revert NoCanonicalProposal();
        
        return _canonical[l2BlockNumber] == GENESIS_SENTINEL ? 0 : _canonical[l2BlockNumber];
    }
    
    function proposalIsCanonical(uint256 proposalId) public view returns (bool) {
        Proposal storage p = proposals[proposalId];
        return _canonicalExistsFor(p.l2BlockNumber) && proposalId == canonicalProposalIdFor(p.l2BlockNumber);
    }

    /// @dev Get the canonical proposal storage reference (reverts if doesn't exist)
    function _canonicalProposalFor(uint256 l2BlockNumber) internal view returns (Proposal storage) {
        uint32 canonicalId = canonicalProposalIdFor(l2BlockNumber);
        
        return proposals[canonicalId];
    }

    /// @dev Check if a canonical proposal exists for an L2 block
    function _canonicalExistsFor(uint256 l2BlockNumber) internal view returns (bool) {
        return _canonical[l2BlockNumber] != 0;
    }

    /// @dev Try to set the canonical proposal for an L2 block (only sets if not already set)
    function _trySetCanonical(uint256 l2BlockNumber, uint32 proposalId) internal {
        if (!_canonicalExistsFor(l2BlockNumber)) {
            _canonical[l2BlockNumber] = proposalId == 0 ? GENESIS_SENTINEL : proposalId;
        }
    }
}

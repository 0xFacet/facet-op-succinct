// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ISP1Verifier } from "@sp1-contracts/src/ISP1Verifier.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { Types } from "src/libraries/Types.sol";
import { Hashing } from "src/libraries/Hashing.sol";
import { SecureMerkleTrie } from "src/libraries/trie/SecureMerkleTrie.sol";
import { SafeCall } from "src/libraries/SafeCall.sol";

import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title Rollup
/// @notice Single-contract fault-proof system: submit → challenge → prove → resolve.
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
    address public constant DEFAULT_L2_SENDER = 0x000000000000000000000000000000000000dEaD;
    uint64 public constant RELAY_RESERVED_GAS = 40_000;

    /*//////////////////////////////////////////////////////////////
                           PORTAL EXTENSION
    //////////////////////////////////////////////////////////////*/
    
    // Portal immutable parameters
    uint256 public immutable MIN_NONCE;            // namespace floor for forks
    Rollup  public immutable PREV_PORTAL;          // 0x0 for genesis

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

    event ProposalSubmitted(uint256 indexed proposalId, uint256 indexed parentId, address indexed proposer, bytes32 root, uint128 l2BlockNumber);
    event ProposalChallenged(uint256 indexed proposalId, address indexed challenger);
    event ProposalProven(uint256 indexed proposalId, address indexed prover);
    event ProposalResolved(uint256 indexed proposalId, ResolutionStatus status);
    event AnchorUpdated(uint256 indexed proposalId, bytes32 root, uint128 l2BlockNumber);
    event ProposalClosed(uint256 indexed proposalId);
    event ProposerPermissionUpdated(address indexed proposer, bool allowed);
    
    // Portal events
    event WithdrawalProven(bytes32 indexed hash, address indexed prover);
    event WithdrawalFinalized(bytes32 indexed hash, bool success);

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error BadAuth();
    error IncorrectBondAmount();
    error AlreadyChallenged();
    error GameNotOver();
    error GameOver();
    error AlreadyResolved();
    error ParentNotResolved();
    error NotFinalized();
    error NoCredit();
    error TransferFailed();
    error InvalidProposalStatus();
    error InvalidParentGame();
    error BadCadence();
    error ParentGameNotResolved();
    
    // Portal errors
    error AlreadyProven();
    error AlreadyFinalized();
    error BelowMinNonce();
    error InvalidRoot();
    error InvalidMerkleProof();
    error Unproven();
    error UnsafeTarget();
    error NonCanonicalProposal();
    error WithdrawalHasValue();
    error NonReentrant();
    error InsufficientGas();
    error PortalPrevIsSelf();

    /*//////////////////////////////////////////////////////////////
                               STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Proposal {
        bytes32 rootClaim;
        bytes32 l1Head;

        // packed slot
        address proposer;
        uint32  l2BlockNumber;
        uint32  parentIndex;
        uint32  deadline;

        uint64  resolvedAt;
        ProposalStatus proposalStatus;
        ResolutionStatus resolutionStatus;
        address challenger;
        address prover;
    }
    
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

    uint32  public anchorProposalId; // index of proposal that is current anchor proposal

    // Portal storage
    mapping(bytes32 => uint64) public withdrawalProvenAt;   // hash → timestamp
    mapping(bytes32 => bool)  public withdrawalFinalized;   // hash → done
    
    // L2 sender address during withdrawal execution
    address public l2Sender;
    uint256 public currentWithdrawalProvedAt;

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
        bytes32 _rangeCommit,
        uint256 _minNonce,
        address _prevPortal
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
        
        // Portal immutables
        MIN_NONCE    = _minNonce;
        PREV_PORTAL  = Rollup(_prevPortal);
        
        // Sanity check: can't point to ourselves
        if (_prevPortal == address(this)) revert PortalPrevIsSelf();

        anchorProposalId      = 0;
        l2Sender              = DEFAULT_L2_SENDER;
        currentWithdrawalProvedAt = type(uint256).max;
        
        // Create genesis proposal representing the starting anchor
        Proposal memory genesis = Proposal({
            l1Head: bytes32(0),
            rootClaim: _startRoot,
            l2BlockNumber: uint32(_startBlock),
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
    /// @param parentId The ID of the parent proposal.
    /// @return proposalId Index of the created proposal.
    function submitProposal(
        bytes32 root,
        uint128 l2BlockNumber,
        uint32  parentId
    ) external payable returns (uint256 proposalId) {
        if (msg.value != PROPOSER_BOND) revert IncorrectBondAmount();
        if (parentId >= proposals.length) revert InvalidParentGame();

        Proposal storage parent = proposals[parentId];
        Proposal storage anchor = proposals[anchorProposalId];
        
        if (l2BlockNumber <= anchor.l2BlockNumber) revert BadCadence();
        if (computeL2Timestamp(l2BlockNumber) >= block.timestamp) revert BadCadence();
        
        if (!proposalAuthorized(msg.sender, l2BlockNumber)) revert BadAuth();
        
        if (l2BlockNumber != parent.l2BlockNumber + PROPOSAL_INTERVAL) {
            revert BadCadence();
        }
        
        if (parent.resolutionStatus == ResolutionStatus.CHALLENGER_WINS) {
            revert InvalidParentGame();
        }
        
        proposals.push();
        proposalId = proposals.length - 1;
        
        Proposal storage p = proposals[proposalId];
        p.l1Head = blockhash(block.number - 1);
        p.rootClaim = root;
        p.l2BlockNumber = uint32(l2BlockNumber);
        p.parentIndex = parentId;
        p.deadline = uint32(block.timestamp + MAX_CHALLENGE_SECS);
        p.proposer = msg.sender;

        emit ProposalSubmitted(proposalId, parentId, msg.sender, root, l2BlockNumber);
    }
    
    function challengeProposal(uint256 id) external payable onlyIfGameNotOver(id) {
        Proposal storage p = proposals[id];
        if (p.proposalStatus != ProposalStatus.Unchallenged) revert AlreadyChallenged();
        if (msg.value != CHALLENGER_BOND) revert IncorrectBondAmount();

        p.challenger = msg.sender;
        p.proposalStatus = ProposalStatus.Challenged;
        p.deadline = uint32(block.timestamp + MAX_PROVE_SECS);

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

    /*//////////////////////////////////////////////////////////////
                          UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function gameOver(uint256 proposalId) public view returns (bool) {
        Proposal storage p = proposals[proposalId];
        return p.deadline < block.timestamp || p.prover != address(0);
    }

    function l2BlockAge(uint256 l2BlockNumber) public view returns (uint256) {
        return block.timestamp - computeL2Timestamp(l2BlockNumber);
    }
    
    /// @notice Returns the L2 timestamp corresponding to a given L2 block number.
    /// @param _l2BlockNumber The L2 block number of the target block.
    /// @return L2 timestamp of the given block.
    function computeL2Timestamp(uint256 _l2BlockNumber) public view returns (uint256) {
        return L2_START_TIMESTAMP + ((_l2BlockNumber - proposals[0].l2BlockNumber) * L2_BLOCK_TIME);
    }

    function resolveProposal(uint256 id) external onlyIfGameOver(id) {
        Proposal storage p = proposals[id];
        Proposal storage parentProposal = proposals[p.parentIndex];
        
        if (parentProposal.resolutionStatus == ResolutionStatus.IN_PROGRESS) {
            revert ParentGameNotResolved();
        }
        
        if (p.resolutionStatus != ResolutionStatus.IN_PROGRESS) revert AlreadyResolved();
        
        uint256 totalBond;
        
        if (p.challenger == address(0)) {
            totalBond = PROPOSER_BOND;
        } else {
            totalBond = PROPOSER_BOND + CHALLENGER_BOND;
        }
        
        if (parentProposal.resolutionStatus == ResolutionStatus.CHALLENGER_WINS) {
            // Parent game is invalid so this game is invalid too. Therefore the challenger wins and gets all bonds.
            // If the game has not been challenged then there will not be any challenger address and the bond is burned.
            p.resolutionStatus = ResolutionStatus.CHALLENGER_WINS;
            credit[p.challenger] += totalBond;
        } else {
            if (p.proposalStatus == ProposalStatus.Challenged) {
                // Challenger wins - no proof provided in time
                p.resolutionStatus = ResolutionStatus.CHALLENGER_WINS;
                credit[p.challenger] += totalBond;
            } else {
                // Defender wins - either unchallenged or proven
                p.resolutionStatus = ResolutionStatus.DEFENDER_WINS;

                if (p.proposalStatus == ProposalStatus.Unchallenged ||
                    p.proposalStatus == ProposalStatus.UnchallengedAndValidProofProvided) {
                    // Simple case: proposer gets their bond back
                    credit[p.proposer] += totalBond;
                } else if (p.proposalStatus == ProposalStatus.ChallengedAndValidProofProvided) {
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

    function setProposer(address proposer, bool allowed) external onlyOwner {
        whitelistedProposer[proposer] = allowed;
        emit ProposerPermissionUpdated(proposer, allowed);
    }

    function allowedProposer(address a) public view returns (bool) {
        return whitelistedProposer[a] || whitelistedProposer[address(0)];
    }

    function proposalAuthorized(address proposer, uint256 proposedL2BlockNumber) public view returns (bool) {
        return allowedProposer(proposer) ||
            (l2BlockAge(proposedL2BlockNumber) > FALLBACK_TIMEOUT_SECS);
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

    /*//////////////////////////////////////////////////////////////
                           PORTAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Prove a withdrawal against a resolved & canonical proposal root.
    /// @dev Reverts if withdrawal has value or if already proven.
    function proveWithdrawal(
        Types.WithdrawalTransaction calldata tx_,
        uint256 proposalId,
        Types.OutputRootProof calldata rootProof,
        bytes[] calldata withdrawalProof
    ) external {
        // Check withdrawal has no value
        if (tx_.value != 0) revert WithdrawalHasValue();
        if (MIN_NONCE != 0 && tx_.nonce < MIN_NONCE) revert BelowMinNonce();

        bytes32 h = Hashing.hashWithdrawal(tx_);
        
        // Check if already proven (prevent double proving)
        if (withdrawalProvenAt[h] != 0) revert AlreadyProven();
        if (_isFinalized(h)) revert AlreadyFinalized();
        
        // No self-calls allowed
        if (tx_.target == address(this)) revert UnsafeTarget();

        // Check proposal is canonical
        Proposal storage prop = proposals[proposalId];
        if (prop.resolutionStatus != ResolutionStatus.DEFENDER_WINS)
            revert NonCanonicalProposal();

        // Root hash must match proposal root
        if (prop.rootClaim != Hashing.hashOutputRootProof(rootProof))
            revert InvalidRoot();

        // Inclusion proof of withdrawal hash in L2ToL1MessagePasser
        bytes32 slotKey = keccak256(abi.encode(h, uint256(0))); // mapping slot 0
        bool ok = SecureMerkleTrie.verifyInclusionProof({
            _key: abi.encode(slotKey),
            _value: hex"01",
            _proof: withdrawalProof,
            _root: rootProof.messagePasserStorageRoot
        });
        if (!ok) revert InvalidMerkleProof();

        withdrawalProvenAt[h] = uint64(block.timestamp);
        emit WithdrawalProven(h, msg.sender);
    }

    /// @notice Finalize a proven withdrawal and relay the call.
    /// @dev Reverts if withdrawal has value. No ETH transfers allowed.
    /// @dev Failed withdrawals can be retried until successful.
    function finalizeWithdrawal(Types.WithdrawalTransaction calldata tx_) external {
        // Reentrancy guard using l2Sender
        if (l2Sender != DEFAULT_L2_SENDER) revert NonReentrant();
        
        bytes32 h = Hashing.hashWithdrawal(tx_);
        
        // Successful withdrawals cannot be replayed
        if (_isFinalized(h)) revert AlreadyFinalized();
        
        // Check proof exists and is mature
        uint64 ts = withdrawalProvenAt[h];
        if (ts == 0) revert Unproven();
        
        // Ensure minimum gas for execution
        if (!SafeCall.hasMinGas(tx_.gasLimit, RELAY_RESERVED_GAS)) {
            revert InsufficientGas();
        }
        
        // No self-calls allowed
        if (tx_.target == address(this)) revert UnsafeTarget();
        
        // Set the l2Sender so contracts know who triggered this withdrawal on L2
        l2Sender = tx_.sender;
        currentWithdrawalProvedAt = ts;
        // Execute call with no value
        bool success = SafeCall.callWithMinGas(
            tx_.target,
            tx_.gasLimit,
            0, // Always 0 value
            tx_.data
        );
        
        // Reset the l2Sender back to the default value
        l2Sender = DEFAULT_L2_SENDER;
        currentWithdrawalProvedAt = type(uint256).max;
        
        // Only mark as finalized on success
        if (success) {
            withdrawalFinalized[h] = true;
        }
        
        emit WithdrawalFinalized(h, success);
    }

    /*//////////////////////////////////////////////////////////////
                         PORTAL HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Check if a withdrawal has been finalized in this or any previous portal.
    /// @param h The withdrawal hash to check.
    function _isFinalized(bytes32 h) internal view returns (bool) {
        return withdrawalFinalized[h] || _finalizedInPrev(h);
    }

    function _finalizedInPrev(bytes32 h) internal view returns (bool) {
        Rollup p = PREV_PORTAL;
        while (address(p) != address(0)) {
            if (p.withdrawalFinalized(h)) return true;
            p = p.PREV_PORTAL();
        }
        return false;
    }
}

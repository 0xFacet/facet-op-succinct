use alloy_sol_macro::sol;

sol! {
    #[sol(rpc)]
    #[derive(Debug, PartialEq)]
    contract Rollup {
        // Events
        event ProposalSubmitted(uint256 indexed proposalId, uint256 indexed parentId, address indexed proposer, bytes32 root, uint128 l2BlockNumber);
        event ProposalChallenged(uint256 indexed proposalId, address indexed challenger);
        event ProposalProven(uint256 indexed proposalId, address indexed prover);
        event ProposalResolved(uint256 indexed proposalId, ResolutionStatus status);
        event AnchorUpdated(uint256 indexed proposalId, bytes32 root, uint128 l2BlockNumber);
        event ProposalClosed(uint256 indexed proposalId);
        event ProposerPermissionUpdated(address indexed proposer, bool allowed);
        event BlockProven(uint128 indexed l2BlockNumber, bytes32 root, address indexed prover);

        // Errors
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

        // Enums
        enum ResolutionStatus { IN_PROGRESS, DEFENDER_WINS, CHALLENGER_WINS }
        
        enum ProposalStatus {
            Unchallenged,
            Challenged,
            UnchallengedAndProven,
            ChallengedAndProven,
            Resolved
        }

        // State variables
        uint256 public immutable MAX_CHALLENGE_SECS;
        uint256 public immutable MAX_PROVE_SECS;
        uint256 public immutable CHALLENGER_BOND;
        uint256 public immutable PROPOSER_BOND;
        uint256 public immutable FALLBACK_TIMEOUT_SECS;
        uint256 public immutable PROPOSAL_INTERVAL;
        uint256 public immutable L2_START_TIMESTAMP;
        uint256 public immutable L2_BLOCK_TIME;

        address public immutable VERIFIER;
        bytes32 public immutable ROLLUP_CONFIG_HASH;
        bytes32 public immutable AGG_VKEY;
        bytes32 public immutable RANGE_VKEY_COMMITMENT;

        uint128 public anchorL2BlockNumber;
        Proposal[] public proposals;
        mapping(address => uint256) public credit;
        mapping(address => bool) public whitelistedProposer;
        mapping(uint256 => bytes32) public l1BlockHashes;
        
        struct Proposal {
            bytes32 rootClaim;
    
            // packed slot
            address proposer;
            uint32  l2BlockNumber;
            uint32  parentIndex;
            uint32  deadline;
    
            uint64  resolvedAt;
            ProposalStatus   proposalStatus;
            ResolutionStatus resolutionStatus;
            address challenger;
            address prover;
        }

        // View functions
        function gameOver(uint256 proposalId) external view returns (bool);
        function l2BlockAge(uint256 l2BlockNumber) external view returns (uint256);
        function computeL2Timestamp(uint256 _l2BlockNumber) external view returns (uint256);
        function anchorRoot() external view returns (bytes32);
        function getProposal(uint256 id) external view returns (Proposal memory);
        function getAnchorRoot() external view returns (bytes32, uint128);
        function getProposals(uint256[] calldata ids) external view returns (Proposal[] memory);
        function latestProposals(uint256 count) external view returns (uint256[] memory);
        function getProposalsLength() external view returns (uint256);
        function isResolvable(uint256 proposalId) external view returns (bool);
        function needsDefense(uint256 proposalId) external view returns (bool);
        function anchorProposalId() external view returns (uint32);
        function canonicalProposalIdFor(uint256 l2BlockNumber) external view returns (uint32);
        function canonicalProposalFor(uint256 l2BlockNumber) external view returns (Proposal memory);
        function isWhitelistedProposer(address proposer) external view returns (bool);
        function isInFallbackWindow(uint256 l2BlockNumber) external view returns (bool);

        // Core functions
        function submitProposal(bytes32 root, uint128 l2BlockNumber, uint32 parentId) external payable returns (uint256 proposalId);
        function challengeProposal(uint256 id) external payable;
        function proveProposal(uint256 id, uint256 l1BlockNumber, bytes calldata proof) external;
        function proveBlock(uint128 l2BlockNumber, bytes32 root, uint256 l1BlockNumber, bytes calldata proof) external;
        function resolveProposal(uint256 id) external;
        function claimCredit(address recipient) external;
        function setProposer(address proposer, bool allowed) external;
        function checkpointL1BlockHash(uint256 l1BlockNumber) external;
    }
}
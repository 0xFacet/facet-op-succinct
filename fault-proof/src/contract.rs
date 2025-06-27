use alloy_sol_macro::sol;

sol! {
    #[sol(rpc)]
    #[derive(Debug, PartialEq)]
    contract Rollup {
        // Events
        event ProposalSubmitted(uint256 indexed proposalId, address indexed proposer, bytes32 root, uint128 l2BlockNumber);
        event ProposalChallenged(uint256 indexed proposalId, address indexed challenger);
        event ProposalProven(uint256 indexed proposalId, address indexed prover);
        event ProposalResolved(uint256 indexed proposalId, ResolutionStatus status);
        event AnchorUpdated(uint256 indexed proposalId, bytes32 root, uint128 l2BlockNumber);
        event ProposalClosed(uint256 indexed proposalId);
        event ProposerPermissionUpdated(address indexed proposer, bool allowed);

        // Errors
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

        // Enums
        enum ResolutionStatus { IN_PROGRESS, DEFENDER_WINS, CHALLENGER_WINS }
        
        enum ProposalStatus {
            Unchallenged,
            Challenged,
            UnchallengedAndValidProofProvided,
            ChallengedAndValidProofProvided,
            Resolved
        }

        // State variables
        uint256 public immutable MAX_CHALLENGE_SECS;
        uint256 public immutable MAX_PROVE_SECS;
        uint256 public immutable CHALLENGER_BOND;
        uint256 public immutable PROPOSER_BOND;
        uint256 public immutable FALLBACK_TIMEOUT_SECS;

        address public immutable VERIFIER;
        bytes32 public immutable ROLLUP_CONFIG_HASH;
        bytes32 public immutable AGG_VKEY;
        bytes32 public immutable RANGE_VKEY_COMMITMENT;

        uint32 public anchorProposalId;
        Proposal[] public proposals;
        mapping(address => uint256) public credit;
        mapping(address => bool) public whitelistedProposer;
        uint256 public lastProposalTimestamp;

        // Proposal struct
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

        // View functions
        function gameOver(uint256 proposalId) external view returns (bool);
        function allowedProposer(address proposer) external view returns (bool);
        function getAnchorRoot() external view returns (bytes32, uint128);
        function getProposal(uint256 id) external view returns (Proposal memory);
        function getAnchorProposal() external view returns (Proposal memory);
        function getProposals(uint256[] calldata ids) external view returns (Proposal[] memory);
        function getProposalsLength() external view returns (uint256);
        function latestProposals(uint256 count) external view returns (uint256[] memory);
        function isResolvable(uint256 proposalId) external view returns (bool);
        function needsDefense(uint256 proposalId) external view returns (bool);

        // Core functions
        function submitProposal(bytes32 root, uint128 l2BlockNumber) external payable returns (uint256 proposalId);
        function challengeProposal(uint256 id) external payable;
        function proveProposal(uint256 id, bytes calldata proof) external;
        function resolveProposal(uint256 id) external;
        function claimCredit(address recipient) external;
        function setProposer(address proposer, bool allowed) external;
    }
}
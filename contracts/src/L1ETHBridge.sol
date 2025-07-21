// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {Types} from "src/libraries/Types.sol";
import {Hashing} from "src/libraries/Hashing.sol";
import {SecureMerkleTrie} from "src/libraries/trie/SecureMerkleTrie.sol";
import {LibFacet} from "facet-sol/src/utils/LibFacet.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {L2ERC20Bridge} from "src/L2ERC20Bridge.sol";
import {Rollup} from "src/Rollup.sol";

/**
 * @title L1ETHBridge
 * @notice Minimal ERC-20 bridge that demonstrates how to use Rollup canonical
 *         proposals to verify withdrawals on L1. Uses a withdrawal delay
 *         for security.
 */
contract L1ETHBridge is Ownable, ReentrancyGuard, Pausable {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    error L2BridgeNotSet();
    error WithdrawalAlreadyProven();
    error WithdrawalAlreadyFinalized();
    error ProposalNotCanonical();
    error InvalidOutputRoot();
    error InvalidWithdrawalProof();
    error WithdrawalNotProven();
    error InvalidDepositAmount();
    error L2BridgeAlreadySet();
    error RootBlacklisted();
    error WithdrawalDelayNotMet();

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    Rollup public rollup;
    address public l2Bridge;
    
    // Training wheels
    mapping(bytes32 => bool) public rootBlacklisted;
    uint256 public withdrawalDelay; // seconds

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    struct ProvenWithdrawal {
        uint32 proposalId;
        uint32 provenAt;
    }

    mapping(bytes32 => mapping(Rollup => ProvenWithdrawal)) public proven;
    mapping(bytes32 => bool) public finalized;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event DepositInitiated(address indexed from, address indexed to, uint256 amount);
    event WithdrawalProven(address indexed rollup, address indexed to, uint256 amount, uint256 nonce, uint256 proposalId);
    event WithdrawalFinalized(address indexed to, uint256 amount, uint256 nonce);
    event RollupUpdated(address indexed oldRollup, address indexed newRollup);
    event RootBlacklistStatusChanged(bytes32 indexed root, bool blacklisted);
    event WithdrawalDelayUpdated(uint256 oldDelay, uint256 newDelay);

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // storage key slot used by the Bedrock L2ToL1MessagePasser contract
    bytes32 internal constant MESSAGE_PASSER_SLOT = bytes32(uint256(0));

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(Rollup _rollup) {
        rollup = _rollup;
    }

    function setL2Bridge(address _l2Bridge) external onlyOwner {
        if (l2Bridge != address(0)) revert L2BridgeAlreadySet();

        l2Bridge = _l2Bridge;
    }
    
    /*//////////////////////////////////////////////////////////////
                           TRAINING WHEELS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Update the rollup contract reference (for upgrades/forks)
     * @param _rollup New rollup contract address
     */
    function setRollup(address _rollup) external onlyOwner {
        address oldRollup = address(rollup);
        rollup = Rollup(_rollup);
        emit RollupUpdated(oldRollup, _rollup);
    }
    
    /**
     * @notice Pause the bridge
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause the bridge
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Blacklist or unblacklist a root
     * @param root The root to blacklist/unblacklist
     * @param blacklisted True to blacklist, false to unblacklist
     */
    function setRootBlacklisted(bytes32 root, bool blacklisted) external onlyOwner {
        rootBlacklisted[root] = blacklisted;
        emit RootBlacklistStatusChanged(root, blacklisted);
    }
    
    /**
     * @notice Update withdrawal delay period
     * @param _withdrawalDelay New delay in seconds
     */
    function setWithdrawalDelay(uint256 _withdrawalDelay) external onlyOwner {
        uint256 oldDelay = withdrawalDelay;
        withdrawalDelay = _withdrawalDelay;
        emit WithdrawalDelayUpdated(oldDelay, _withdrawalDelay);
    }

    /*//////////////////////////////////////////////////////////////
                                  DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function initiateDeposit() public payable virtual whenNotPaused {
        if (l2Bridge == address(0)) revert L2BridgeNotSet();

        uint256 amount = msg.value;
        address recipient = msg.sender;

        if (amount == 0) revert InvalidDepositAmount();

        bytes memory data = abi.encodeWithSelector(L2ERC20Bridge.finalizeDeposit.selector, recipient, amount);

        LibFacet.sendFacetTransaction({to: l2Bridge, gasLimit: 1_000_000, data: data});

        emit DepositInitiated(recipient, recipient, amount);
    }

    receive() external payable {
        initiateDeposit();
    }

    /*//////////////////////////////////////////////////////////////
                             WITHDRAWAL – PROVE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Prove a withdrawal by verifying merkle proof against canonical L2 state
     * @param amount Amount of tokens to withdraw
     * @param to Recipient address on L1
     * @param nonce Withdrawal nonce from L2
     * @param proposalId The canonical proposal ID from Rollup contract
     * @param rootProof The merkle proof components from the L2 output root
     * @param withdrawalProof Merkle proof path in the L2ToL1MessagePasser storage trie
     */
    function proveWithdrawal(
        address to,
        uint256 amount,
        uint256 nonce,
        uint256 proposalId,
        Types.OutputRootProof calldata rootProof,
        bytes[] calldata withdrawalProof
    ) external virtual whenNotPaused {
        bytes32 withdrawalHash = _hashWithdrawal(to, amount, nonce);

        ProvenWithdrawal storage info = proven[withdrawalHash][rollup];

        if (info.provenAt != 0) revert WithdrawalAlreadyProven();
        if (finalized[withdrawalHash]) revert WithdrawalAlreadyFinalized();
        if (!rollup.proposalIsCanonical(proposalId)) revert ProposalNotCanonical();

        Rollup.Proposal memory prop = rollup.getProposal(proposalId);
        
        // Check if root is blacklisted
        if (rootBlacklisted[prop.rootClaim]) revert RootBlacklisted();

        if (prop.rootClaim != Hashing.hashOutputRootProof(rootProof)) revert InvalidOutputRoot();

        // verify inclusion of message in L2 storage
        bytes32 storageKey = keccak256(abi.encode(withdrawalHash, uint256(0))); // slot 0
        bool valid = SecureMerkleTrie.verifyInclusionProof({
            _key: abi.encode(storageKey),
            _value: hex"01", // value of 1 indicates withdrawal exists
            _proof: withdrawalProof,
            _root: rootProof.messagePasserStorageRoot
        });
        if (!valid) revert InvalidWithdrawalProof();

        proven[withdrawalHash][rollup] = ProvenWithdrawal({
            proposalId: uint32(proposalId),
            provenAt: uint32(block.timestamp)
        });

        emit WithdrawalProven(address(rollup), to, amount, nonce, proposalId);
    }

    /*//////////////////////////////////////////////////////////////
                            WITHDRAWAL – FINALIZE
    //////////////////////////////////////////////////////////////*/

    function finalizeWithdrawal(address to, uint256 amount, uint256 nonce) external nonReentrant whenNotPaused {
        bytes32 withdrawalHash = _hashWithdrawal(to, amount, nonce);

        ProvenWithdrawal storage info = proven[withdrawalHash][rollup];

        if (info.provenAt == 0) revert WithdrawalNotProven();
        if (finalized[withdrawalHash]) revert WithdrawalAlreadyFinalized();
        
        // Respect safety delay
        if (block.timestamp <= info.provenAt + withdrawalDelay) revert WithdrawalDelayNotMet();
        
        // Check if the root of the proposal used for proving is blacklisted
        Rollup.Proposal memory prop = rollup.getProposal(info.proposalId);
        if (rootBlacklisted[prop.rootClaim]) revert RootBlacklisted();

        finalized[withdrawalHash] = true;

        to.forceSafeTransferETH(amount, SafeTransferLib.GAS_STIPEND_NO_STORAGE_WRITES);

        emit WithdrawalFinalized(to, amount, nonce);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _hashWithdrawal(address to, uint256 amount, uint256 nonce) internal view returns (bytes32) {
        bytes memory data = abi.encode(to, amount);
        Types.WithdrawalTransaction memory w = Types.WithdrawalTransaction({
            nonce: nonce,
            sender: l2Bridge,
            target: address(this),
            value: 0,
            gasLimit: 0,
            data: data
        });
        return Hashing.hashWithdrawal(w);
    }
}

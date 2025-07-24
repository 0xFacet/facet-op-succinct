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
import {L2Bridge} from "src/L2Bridge.sol";
import {Rollup} from "src/Rollup.sol";

/**
 * @title L1Bridge
 * @notice L1 ETH bridge that accepts deposits and uses ZK proofs to verify withdrawal claims.
 * 
 * @dev CRITICAL ARCHITECTURE NOTICE FOR USERS:
 * 
 * This bridge verifies withdrawals using ZK proofs from a Rollup contract. Unlike bridges that
 * rely on upgradeable proof systems, each Rollup contract here is immutable - hardcoded to prove
 * one specific state transition function forever.
 * 
 * KEY IMPLICATIONS:
 * 
 * 1. FORK HANDLING: When the L2 network upgrades, this bridge won't automatically recognize the
 *    new rules. The bridge owner must call setRollup() to point to a new Rollup contract that
 *    proves the updated state transition function.
 * 
 * 2. OWNERSHIP TRADE-OFFS:
 *    - With active owner: Can adapt to forks but requires trusting the owner won't set a 
 *      malicious rollup contract
 *    - With renounced ownership: Becomes trustless* with respect to human operators,
 *      but permanently locked to a single fork's rules (*Security depends solely on the ZK proof 
 *      system and smart contract correctness)
 * 
 * 3. TRUST MODELS: Users can choose between:
 *    - Active ownership: Trust a human operator to handle forks properly (more flexible)
 *    - Renounced ownership: Trust only the code and ZK proofs (more secure but less flexible)
 * 
 * 4. FORK INCOMPATIBILITY: If the L2 network forks and modifies how bridged assets work, but
 *    this bridge isn't updated to point to a new Rollup contract, those modifications won't be
 *    reflected in withdrawal capabilities. Your assets remain subject to the original rules.
 * 
 * RECOMMENDATION: Before depositing, verify:
 * - Current owner status: check owner() - address(0) means renounced
 * - If owned: research the owner's reputation and track record
 * - Which Rollup contract is currently being used (check rollup() function)
 * - Your preference: human-free operation vs flexibility for upgrades
 */
contract L1Bridge is Ownable, ReentrancyGuard, Pausable {
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
     * @notice Update the rollup contract reference to support new forks or state transition rules.
     * @dev CRITICAL: This function enables fork flexibility but also represents the primary
     *      trust assumption. If ownership is renounced, this function becomes inaccessible,
     *      making the bridge trustless (no human control) but locked to the current state transition rules.
     * @param _rollup New rollup contract address that proves the updated state transition rules
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

        bytes memory data = abi.encodeWithSelector(L2Bridge.finalizeDeposit.selector, recipient, amount);

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
     * @dev This verification is bound to the current rollup contract's state transition rules.
     *      If the L2 forks but this bridge's rollup reference isn't updated, withdrawals
     *      must still conform to the original state transition function's rules.
     * @param amount Amount of tokens to withdraw
     * @param to Recipient address on L1
     * @param nonce Withdrawal nonce from L2
     * @param proposalId The canonical proposal ID from current Rollup contract
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

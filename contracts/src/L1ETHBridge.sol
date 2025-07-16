// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Types} from "src/libraries/Types.sol";
import {Hashing} from "src/libraries/Hashing.sol";
import {SecureMerkleTrie} from "src/libraries/trie/SecureMerkleTrie.sol";
import {LibFacet} from "facet-sol/src/utils/LibFacet.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {L2ERC20Bridge} from "src/L2ERC20Bridge.sol";

interface IRollup {
    struct Proposal {
        bytes32 rootClaim;
        address proposer;
        uint32 l2BlockNumber;
        uint32 parentIndex;
        uint32 deadline;
        uint64 resolvedAt;
        uint8 proposalStatus;
        uint8 resolutionStatus;
        address challenger;
        address prover;
    }

    function getProposal(uint256 id) external view returns (Proposal memory);
    function proposalIsCanonical(uint256 proposalId) external view returns (bool);
}

/**
 * @title L1ETHBridge
 * @notice Minimal ERC-20 bridge that demonstrates how to use Rollup canonical
 *         proposals to verify withdrawals on L1. Uses a withdrawal delay
 *         for security.
 */
contract L1ETHBridge is Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    error L2BridgeNotSet();
    error WithdrawalAlreadyProven();
    error WithdrawalAlreadyFinalised();
    error ProposalNotCanonical();
    error InvalidOutputRoot();
    error InvalidWithdrawalProof();
    error WithdrawalNotProven();
    error InvalidDepositAmount();
    error L2BridgeAlreadySet();

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    IRollup public immutable rollup;
    address public l2Bridge;

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    struct ProvenWithdrawal {
        uint32 proposalId;
        uint32 provenAt;
    }

    // withdrawalHash => ProvenWithdrawal
    mapping(bytes32 => ProvenWithdrawal) public proven;
    // withdrawalHash => finalised?
    mapping(bytes32 => bool) public finalised;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event DepositInitiated(address indexed from, address indexed to, uint256 amount);
    event WithdrawalProven(address indexed to, uint256 amount, uint256 nonce, uint256 proposalId);
    event WithdrawalFinalised(address indexed to, uint256 amount, uint256 nonce);

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // storage key slot used by the Bedrock L2ToL1MessagePasser contract
    bytes32 internal constant MESSAGE_PASSER_SLOT = bytes32(uint256(0));

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IRollup _rollup) {
        rollup = _rollup;
    }

    function setL2Bridge(address _l2Bridge) external onlyOwner {
        if (l2Bridge != address(0)) revert L2BridgeAlreadySet();

        l2Bridge = _l2Bridge;
    }

    /*//////////////////////////////////////////////////////////////
                                  DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function initiateDeposit() public payable virtual {
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
    ) external virtual {
        bytes32 withdrawalHash = _hashWithdrawal(to, amount, nonce);

        if (proven[withdrawalHash].provenAt != 0) revert WithdrawalAlreadyProven();
        if (finalised[withdrawalHash]) revert WithdrawalAlreadyFinalised();

        IRollup.Proposal memory prop = rollup.getProposal(proposalId);

        if (!rollup.proposalIsCanonical(proposalId)) revert ProposalNotCanonical();

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

        proven[withdrawalHash] = ProvenWithdrawal({proposalId: uint32(proposalId), provenAt: uint32(block.timestamp)});

        emit WithdrawalProven(to, amount, nonce, proposalId);
    }

    /*//////////////////////////////////////////////////////////////
                            WITHDRAWAL – FINALISE
    //////////////////////////////////////////////////////////////*/

    function finaliseWithdrawal(address to, uint256 amount, uint256 nonce) external nonReentrant {
        bytes32 withdrawalHash = _hashWithdrawal(to, amount, nonce);

        ProvenWithdrawal memory info = proven[withdrawalHash];

        if (info.provenAt == 0) revert WithdrawalNotProven();
        if (finalised[withdrawalHash]) revert WithdrawalAlreadyFinalised();

        finalised[withdrawalHash] = true;

        to.forceSafeTransferETH(amount, SafeTransferLib.GAS_STIPEND_NO_STORAGE_WRITES);

        emit WithdrawalFinalised(to, amount, nonce);
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

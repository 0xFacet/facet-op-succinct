// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AddressAliasHelper} from "optimism/packages/contracts-bedrock/src/vendor/AddressAliasHelper.sol";
import {L1Bridge} from "src/L1Bridge.sol";

interface IL2ToL1MessagePasser {
    function initiateWithdrawal(address _target, uint256 _gasLimit, bytes calldata _data) external payable;
}

/**
 * @title L2Bridge
 * @notice L2 side of the ETH bridge that mints wrapped ETH tokens on FACET L2
 * @dev This contract handles:
 *      - Finalizing deposits from L1 by minting wrapped ETH
 *      - Initiating withdrawals back to L1 by burning wrapped ETH
 *      - Replay protection to prevent double-spending of deposits
 *      Only the aliased L1 bridge address can finalize deposits.
 */
contract L2Bridge is ERC20 {
    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnauthorizedBridge();
    error InvalidWithdrawalAmount();
    error InvalidL1Bridge();
    error DepositAlreadyFinalized();

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address public immutable l1Bridge;
    IL2ToL1MessagePasser public constant MESSAGE_PASSER =
        IL2ToL1MessagePasser(0x4200000000000000000000000000000000000016);
    
    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Tracks which deposit nonces have been finalized
     * @dev Prevents replay attacks where the same deposit could be finalized multiple times.
     *      This is critical for FACET's retry mechanism - a deposit can be retried on L1
     *      but must only be finalized once on L2.
     */
    mapping(uint256 => bool) public finalizedDeposits;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event DepositFinalized(uint256 indexed nonce, address indexed to, uint256 amount);
    event WithdrawalInitiated(address indexed from, address indexed to, uint256 amount);

    /**
     * @notice Modifier to restrict functions to only the aliased L1 bridge
     * @dev Ensures only legitimate cross-chain messages from L1 bridge can mint tokens
     */
    modifier onlyL1Bridge() {
        if (msg.sender != aliasedL1Bridge()) revert UnauthorizedBridge();
        _;
    }

    constructor(string memory name_, string memory symbol_, address _l1Bridge) ERC20(name_, symbol_) {
        if (_l1Bridge == address(0)) revert InvalidL1Bridge();
        l1Bridge = _l1Bridge;
    }

    /*//////////////////////////////////////////////////////////////
                               DEPOSIT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Finalizes a deposit from L1 by minting wrapped ETH to the recipient
     * @dev Called by the L1 bridge via cross-chain message. Uses nonce-based replay protection
     *      to ensure each deposit is only finalized once, even if retried multiple times on L1
     *      due to FACET block gas limits.
     * @param deposit The deposit transaction containing nonce, recipient, and amount
     */
    function finalizeDeposit(
        L1Bridge.DepositTransaction calldata deposit
    ) external onlyL1Bridge {
        // Check if deposit has already been finalized
        if (finalizedDeposits[deposit.nonce]) revert DepositAlreadyFinalized();
        
        // Mark deposit as finalized
        finalizedDeposits[deposit.nonce] = true;
        
        // Mint tokens to recipient
        _mint(deposit.to, deposit.amount);
        
        emit DepositFinalized(deposit.nonce, deposit.to, deposit.amount);
    }

    /*//////////////////////////////////////////////////////////////
                              WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initiates a withdrawal of wrapped ETH back to L1
     * @dev Burns the wrapped ETH and sends a message to L1 via the L2ToL1MessagePasser.
     *      The withdrawal must be proven and finalized on L1 using merkle proofs.
     * @param to The address that will receive the ETH on L1
     * @param amount The amount of wrapped ETH to withdraw (burned on L2, received on L1)
     */
    function initiateWithdrawal(address to, uint256 amount) external {
        if (amount == 0) revert InvalidWithdrawalAmount();

        _burn(msg.sender, amount);

        bytes memory data = abi.encode(to, amount);

        MESSAGE_PASSER.initiateWithdrawal(l1Bridge, 0, data);

        emit WithdrawalInitiated(msg.sender, to, amount);
    }

    /**
     * @notice Returns the aliased L1 bridge address
     * @dev L1 to L2 messages have their sender address aliased for security.
     *      This function computes what the L1 bridge address becomes when aliased.
     * @return The aliased address of the L1 bridge
     */
    function aliasedL1Bridge() public view returns (address) {
        return AddressAliasHelper.applyL1ToL2Alias(l1Bridge);
    }
}

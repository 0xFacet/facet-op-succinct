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
 * @notice Simple L2 side of an ERC-20 bridge. Only the authorised L1 bridge
 *         may mint tokens; anyone may burn to withdraw back to L1.
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
    
    // Tracks which deposits have been finalized to prevent replay attacks
    mapping(uint256 => bool) public finalizedDeposits;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event DepositFinalized(uint256 indexed nonce, address indexed to, uint256 amount);
    event WithdrawalInitiated(address indexed from, address indexed to, uint256 amount);

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

    function initiateWithdrawal(address to, uint256 amount) external {
        if (amount == 0) revert InvalidWithdrawalAmount();

        _burn(msg.sender, amount);

        bytes memory data = abi.encode(to, amount);

        MESSAGE_PASSER.initiateWithdrawal(l1Bridge, 0, data);

        emit WithdrawalInitiated(msg.sender, to, amount);
    }

    function aliasedL1Bridge() public view returns (address) {
        return AddressAliasHelper.applyL1ToL2Alias(l1Bridge);
    }
}

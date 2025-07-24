// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AddressAliasHelper} from "optimism/packages/contracts-bedrock/src/vendor/AddressAliasHelper.sol";

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

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address public immutable l1Bridge;
    IL2ToL1MessagePasser public constant MESSAGE_PASSER =
        IL2ToL1MessagePasser(0x4200000000000000000000000000000000000016);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event DepositFinalized(address indexed to, uint256 amount);
    event WithdrawalInitiated(address indexed from, address indexed to, uint256 amount);

    modifier onlyL1Bridge() {
        if (msg.sender != aliasedL1Bridge()) revert UnauthorizedBridge();
        _;
    }

    constructor(string memory name_, string memory symbol_, address _l1Bridge) ERC20(name_, symbol_) {
        l1Bridge = _l1Bridge;
    }

    /*//////////////////////////////////////////////////////////////
                               DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function finalizeDeposit(address to, uint256 amount) external onlyL1Bridge {
        _mint(to, amount);
        emit DepositFinalized(to, amount);
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

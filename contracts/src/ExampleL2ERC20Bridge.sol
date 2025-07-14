// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AddressAliasHelper } from "optimism/packages/contracts-bedrock/src/vendor/AddressAliasHelper.sol";

interface IL1Bridge {
    function finalizeERC20Withdrawal(uint256 amount, address to) external;
}

interface IL2ToL1MessagePasser {
    function initiateWithdrawal(address _target, uint256 _gasLimit, bytes calldata _data) external payable;
}

/**
 * @title ExampleL2ERC20Bridge
 * @notice L2 side of an ERC-20 bridge. Accepts deposits only from the L1 bridge.
 *         Withdrawals burn tokens and send a message to the L1 bridge via the message passer.
 */
contract ExampleL2ERC20Bridge is ERC20, Ownable {
    address public l1Bridge;
    address public constant MESSAGE_PASSER = 0x4200000000000000000000000000000000000016;
    uint256 public constant WITHDRAWAL_GAS_LIMIT = 100_000;

    modifier onlyL1Bridge() {
        require(msg.sender == AddressAliasHelper.applyL1ToL2Alias(l1Bridge), "not L1 bridge");
        _;
    }

    constructor(
      string memory name_,
      string memory symbol_,
      address _l1Bridge
    ) ERC20(name_, symbol_) {
        l1Bridge = _l1Bridge;
    }

    // Called by L1 bridge to mint tokens for a user
    function finalizeERC20Deposit(uint256 amount, address to) external onlyL1Bridge {
        _mint(to, amount);
    }

    // Called by user to withdraw tokens to L1
    function withdraw(uint256 amount, address to) external {
        _burn(msg.sender, amount);
        
        bytes memory data = abi.encodeWithSelector(
            IL1Bridge.finalizeERC20Withdrawal.selector,
            amount,
            to
        );
        
        IL2ToL1MessagePasser(MESSAGE_PASSER).initiateWithdrawal(
            l1Bridge,
            WITHDRAWAL_GAS_LIMIT,
            data
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title EOA
 * @notice A library for detecting if an address is an EOA.
 * @dev Includes support for EIP-7702 delegated EOAs
 */
library EOA {
    /**
     * @notice Returns true if sender address is an EOA.
     * @dev Checks for regular EOAs and EIP-7702 delegated EOAs
     * @return isEOA_ True if the sender address is an EOA.
     */
    function isSenderEOA() internal view returns (bool isEOA_) {
        if (msg.sender == tx.origin) {
            // Regular EOA: sender is the transaction origin
            isEOA_ = true;
        } else if (address(msg.sender).code.length == 23) {
            // Check for EIP-7702 delegated EOAs (23 bytes of code)
            assembly {
                let ptr := mload(0x40)
                mstore(0x40, add(ptr, 0x20))
                extcodecopy(caller(), ptr, 0, 0x20)
                isEOA_ := eq(shr(232, mload(ptr)), 0xEF0100)
            }
        } else {
            // If more or less than 23 bytes of code, not a 7702 delegated EOA
            isEOA_ = false;
        }
    }
}
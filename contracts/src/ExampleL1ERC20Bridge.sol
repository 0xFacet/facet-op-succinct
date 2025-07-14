// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 }      from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }   from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable }     from "@openzeppelin/contracts/access/Ownable.sol";
import { Rollup }      from "./Rollup.sol";
import { LibFacet } from "facet-sol/src/utils/LibFacet.sol";

interface l2Bridge {
    function finalizeERC20Deposit(uint256 amount, address to) external;
}

/**
 * @title ExampleL1ERC20Bridge
 * @notice L1 side of an ERC-20 bridge that relies on Rollup's
 *         withdrawal portal.  Deposits just lock tokens and
 *         (stub) send a message to the L2 bridge; withdrawals are
 *         executed only when the Rollup calls back after a proven
 *         & finalized withdrawal.
 *
 * Training-wheels:
 *   • `paused` flag blocks every withdrawal.
 *   • Owner can blacklist individual proposal roots.
 */
contract ExampleL1ERC20Bridge is Ownable {
    using SafeERC20 for IERC20;

    Rollup public immutable ROLLUP;
    address public immutable L2_BRIDGE;
    uint256 public immutable WITHDRAWAL_DELAY; // seconds
    IERC20 public immutable TOKEN;

    bool public paused;
    mapping(bytes32 => bool) public rootBlacklisted; // proposal root → blocked?

    constructor(
        Rollup  _rollup,
        address _l2Bridge,
        uint256 _withdrawalDelaySecs,
        IERC20 _token
    ) {
        ROLLUP           = _rollup;
        L2_BRIDGE        = _l2Bridge;
        WITHDRAWAL_DELAY = _withdrawalDelaySecs;
        TOKEN            = _token;
    }

    /*───────────────────────────────────────────────────────────
                                DEPOSIT
    ───────────────────────────────────────────────────────────*/

    function depositERC20(
        uint256 amount,
        address to
    ) external {
        TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        
        bytes memory bridgeInData = abi.encodeWithSelector(
            l2Bridge.finalizeERC20Deposit.selector,
            amount,
            to
        );
        
        LibFacet.sendFacetTransaction({
            to: L2_BRIDGE,
            gasLimit: 1_000_000,
            data: bridgeInData
        });
    }

    /**
     * @dev Called by Rollup.finalizeWithdrawal via SafeCall.
     *      Calldata must decode to (IERC20 token, uint256 amount, address to).
     *      No ether ever transferred.
     */
    function finalizeERC20Withdrawal(
        uint256 amount,
        address to
    ) external {
        // 1. Must originate from the Rollup portal
        require(msg.sender == address(ROLLUP), "caller not rollup");

        // 2. Read withdrawal context
        (
            address l2Sender,
            uint32  proposalId,
            uint32  provenAt
        ) = ROLLUP.currentWithdrawal();

        // 3. Verify L2 sender is the canonical bridge
        require(l2Sender == L2_BRIDGE, "bad L2 sender");

        // 4. Respect safety delay
        require(block.timestamp > provenAt + WITHDRAWAL_DELAY,
                "withdrawal still in challenge window");

        // 5. Proposal root must not be black-listed
        bytes32 root = ROLLUP.getProposal(proposalId).rootClaim;
        require(!rootBlacklisted[root], "root black-listed");

        // 6. Bridge must not be paused
        require(!paused, "bridge paused");

        // 7. Unlock funds
        TOKEN.safeTransfer(to, amount);
    }

    /*───────────────────────────────────────────────────────────
                         TRAINING-WHEELS CONTROLS
    ───────────────────────────────────────────────────────────*/

    function pause(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function setRootBlacklisted(bytes32 root, bool blocked)
        external
        onlyOwner
    {
        rootBlacklisted[root] = blocked;
    }
}
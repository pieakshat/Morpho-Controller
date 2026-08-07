// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBundler3} from "../interfaces/IBundler3.sol";

/// @notice Executes one arbitrary-target swap and enforces a slippage floor on-chain.
/// @dev This is the piece that makes accepting arbitrary {target, callData} in a
///      MarketAction survivable — without it, minOut would just be a number nobody
///      checks. Expects tokenIn to already be sitting in this contract's own balance,
///      transferred in by a prior Bundler3 step: one Call moves tokens in, a separate
///      Call executes the swap.
///
///      Deployed by its owning vault (see MorphoCore), so VAULT is that vault and no
///      other contract can ever share this instance.
contract MorphoSwapExecutor {
    using SafeERC20 for IERC20;

    error SlippageExceeded(uint256 received, uint256 minOut);
    error SwapCallFailed();
    error UnauthorizedCaller();

    /// @notice The vault this executor belongs to. Set to the deployer, which is the vault
    ///         itself since MorphoCore constructs this contract.
    address public immutable VAULT;
    /// @notice The Bundler3 instance whose `initiator()` this executor trusts to attribute
    ///         a call to the vault, since msg.sender on a bundled call is Bundler3 itself.
    IBundler3 public immutable BUNDLER3;

    constructor(IBundler3 bundler3_) {
        BUNDLER3 = bundler3_;
        VAULT = msg.sender;
    }

    /// @dev executeSwap runs inside a Bundler3 bundle, so msg.sender is Bundler3, not the
    ///      vault. Bundler3 is permissionless, so gating on msg.sender alone would let
    ///      anyone route a call here through their own bundle. Gate on the bundle's
    ///      initiator instead: it is the vault only while the vault's own bundle is in
    ///      flight, and the zero address outside any bundle.
    modifier onlyVaultBundle() {
        if (msg.sender != address(BUNDLER3) || BUNDLER3.initiator() != VAULT) revert UnauthorizedCaller();
        _;
    }

    /// @notice Swaps this contract's entire current balance of `tokenIn` through
    ///         `target` using `data`, then sends the resulting `tokenOut` to `recipient`.
    /// @dev `minOut` is enforced here but is chosen by the caller, so it is not on its own
    ///      a defense against a malicious allocator. The binding floor is derived from the
    ///      market oracle in MorphoLeverageEngine before this is ever reached; by the time
    ///      a value lands here it has already been raised to at least that floor.
    ///
    ///      Both token balances are zeroed before returning. Leaving anything behind would
    ///      be unrecoverable value at best, and a standing target at worst, since a swap
    ///      target that under-consumes its allowance is entirely normal for real routers.
    function executeSwap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 minOut,
        address target,
        bytes calldata data,
        address recipient
    ) external onlyVaultBundle {
        uint256 amountIn = tokenIn.balanceOf(address(this));
        uint256 balanceOutBefore = tokenOut.balanceOf(address(this));

        tokenIn.forceApprove(target, amountIn);
        (bool ok,) = target.call(data);
        if (!ok) revert SwapCallFailed();
        tokenIn.forceApprove(target, 0);

        uint256 received = tokenOut.balanceOf(address(this)) - balanceOutBefore;
        if (received < minOut) revert SlippageExceeded(received, minOut);

        tokenOut.safeTransfer(recipient, received);

        // Sweep whatever the swap did not consume, plus any pre-existing tokenOut that the
        // balanceOutBefore baseline deliberately excluded from `received`. Goes to the
        // vault rather than `recipient`: during a leveraged operation `recipient` is the
        // shared GeneralAdapter1, where a surplus above the flashloan repayment would be
        // stranded for anyone to take.
        uint256 residualIn = tokenIn.balanceOf(address(this));
        if (residualIn > 0) tokenIn.safeTransfer(VAULT, residualIn);

        uint256 residualOut = tokenOut.balanceOf(address(this));
        if (residualOut > 0) tokenOut.safeTransfer(VAULT, residualOut);
    }
}

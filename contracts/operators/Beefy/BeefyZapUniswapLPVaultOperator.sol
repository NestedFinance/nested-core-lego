// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.11;

import "./BeefyVaultStorage.sol";
import "./../../libraries/ExchangeHelpers.sol";
import "./../../libraries/BeefyZapperHelpers.sol";
import "./../../interfaces/external/IBeefyVaultV6.sol";
import "@uniswap/lib/contracts/libraries/Babylonian.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title (Zapper) Beefy UniswapV2 LP Vault Operator.
/// @notice Deposit/Withdraw in a Beefy UniswapV2 LP vault using zapper
/// Note: "Zap" means that we are converting an asset for the LP Token by
///       swapping and adding liquidity.
contract BeefyZapUniswapLPVaultOperator {
    using SafeERC20 for IERC20;

    BeefyVaultStorage public immutable operatorStorage;

    constructor(address[] memory vaults, address[] memory routers) {
        uint256 vaultsLength = vaults.length;
        require(vaultsLength == routers.length, "BLVO: INVALID_VAULTS_LENGTH");

        operatorStorage = new BeefyVaultStorage();

        for (uint256 i; i < vaultsLength; i++) {
            operatorStorage.addVault(vaults[i], routers[i]);
        }

        operatorStorage.transferOwnership(msg.sender);
    }

    /// @notice Zap one of the paired tokens for the LP Token, deposit the
    ///         asset in the Beefy vault and receive the vault token (moo).
    /// @param vault The vault address to deposit into
    /// @param token The token to zap
    /// @param amountToDeposit The token amount to deposit
    /// @param minVaultAmount The minimum vault token amount expected
    /// @return amounts Array of amounts :
    ///         - [0] : The vault token received amount
    ///         - [1] : The token deposited amount
    /// @return tokens Array of token addresses
    ///         - [0] : The vault token received address
    ///         - [1] : The token deposited address
    function deposit(
        address vault,
        IERC20 token,
        uint256 amountToDeposit,
        uint256 minVaultAmount
    ) external payable returns (uint256[] memory amounts, address[] memory tokens) {
        require(amountToDeposit != 0, "BLVO: INVALID_AMOUNT");
        address router = operatorStorage.vaults(vault);
        require(router != address(0), "BLVO: INVALID_VAULT");
        amounts = new uint256[](2);
        tokens = new address[](2);

        uint256 vaultBalanceBefore = IERC20(vault).balanceOf(address(this));
        uint256 tokenBalanceBefore = token.balanceOf(address(this));

        _zapAndStakeLp(router, IBeefyVaultV6(vault), token, amountToDeposit);

        uint256 vaultAmount = IERC20(vault).balanceOf(address(this)) - vaultBalanceBefore;
        uint256 depositedAmount = tokenBalanceBefore - token.balanceOf(address(this));

        require(vaultAmount != 0 && vaultAmount >= minVaultAmount, "BLVO: INVALID_AMOUNT_RECEIVED");
        require(depositedAmount != 0 && amountToDeposit >= depositedAmount, "BLVO: INVALID_AMOUNT_DEPOSITED");

        // Output amounts
        amounts[0] = vaultAmount;
        amounts[1] = depositedAmount;

        // Output token
        tokens[0] = vault;
        tokens[1] = address(token);
    }

    /// @notice Withdraw the vault token (moo) from Beefy and receive
    ///         one of the paired tokens
    /// @param vault The vault address to withdraw from
    /// @param amount The vault token amount to withdraw
    /// @param token One of the paired token
    /// @param minTokenAmount The minimum token amount expected
    /// @return amounts Array of amounts :
    ///         - [0] : The token received amount
    ///         - [1] : The vault token deposited amount
    /// @return tokens Array of token addresses
    ///         - [0] : The token received address
    ///         - [1] : The vault token deposited address
    function withdraw(
        address vault,
        uint256 amount,
        IERC20 token,
        uint256 minTokenAmount
    ) external returns (uint256[] memory amounts, address[] memory tokens) {
        require(amount != 0, "BLVO: INVALID_AMOUNT");
        address router = operatorStorage.vaults(vault);
        require(router != address(0), "BLVO: INVALID_VAULT");

        amounts = new uint256[](2);
        tokens = new address[](2);

        uint256 tokenBalanceBefore = token.balanceOf(address(this));
        uint256 vaultBalanceBefore = IERC20(vault).balanceOf(address(this));

        _withdrawAndSwap(router, vault, amount, address(token));

        uint256 tokenAmount = token.balanceOf(address(this)) - tokenBalanceBefore;
        uint256 vaultAmount = vaultBalanceBefore - IERC20(vault).balanceOf(address(this));
        require(vaultAmount == amount, "BLVO: INVALID_AMOUNT_WITHDRAWED");
        require(tokenAmount >= minTokenAmount, "BLVO: INVALID_OUTPUT_AMOUNT");

        // Output amounts
        amounts[0] = tokenAmount;
        amounts[1] = amount;

        // Output token
        tokens[0] = address(token);
        tokens[1] = vault;
    }

    /// @notice Perform a vault token withdraw (moo) from Beefy, and
    ///         transfer the rest as one of the paired token.abi
    /// @param router The uniswap v2 router address to use for swaping and adding liquidity
    /// @param vault The vault address to withdraw from
    /// @param amount The vault token amount to withdraw
    /// @param token One of the paired token
    function _withdrawAndSwap(
        address router,
        address vault,
        uint256 amount,
        address token
    ) private {
        IUniswapV2Router02 uniswapRouter = IUniswapV2Router02(router);
        IBeefyVaultV6(vault).withdraw(amount);

        address pair = IBeefyVaultV6(vault).want();

        (address[] memory path, uint256 tokenAmountIn) = BeefyZapperHelpers.removeLiquidityAndSetupSwap(
            pair,
            token,
            router
        );

        // Slippage 100% since we are checking the final amount (minTokenAmount) for the slippage
        uniswapRouter.swapExactTokensForTokens(tokenAmountIn, 0, path, address(this), block.timestamp);
    }

    /// @dev Zap one of the paired tokens for the LP Token, deposit the
    ///         asset in the Beefy vault and receive the vault token (moo)
    /// @param router The uniswap v2 router address to use for swaping and adding liquidity
    /// @param vault The vault address to deposit into
    /// @param token The token to zap
    /// @param amount The token amount to deposit
    function _zapAndStakeLp(
        address router,
        IBeefyVaultV6 vault,
        IERC20 token,
        uint256 amount
    ) private {
        IUniswapV2Router02 uniswapRouter = IUniswapV2Router02(router);
        IUniswapV2Pair pair = IUniswapV2Pair(vault.want());

        require(pair.factory() == uniswapRouter.factory(), "BLVO: INVALID_VAULT");

        (address[] memory path, bool isInput0) = BeefyZapperHelpers.setupAddLiquiditySwap(
            pair,
            address(vault),
            router,
            address(token)
        );

        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();

        // The amount of input token to swap
        // to get the same value of output token
        uint256 swapAmountIn;
        if (isInput0) {
            swapAmountIn = _getOptimalSwapAmount(amount, reserve0, reserve1, uniswapRouter);
        } else {
            swapAmountIn = _getOptimalSwapAmount(amount, reserve1, reserve0, uniswapRouter);
        }

        uint256 lpAmount = _swapAndAddLiquidity(amount, swapAmountIn, path, uniswapRouter);
        vault.deposit(lpAmount);
    }

    /// @dev Swap input tokenA into TokenB to get the same value in tokenA
    ///         as in tokenB to then add liquidity and store the obtained LP
    ///         token in the vault beefy.
    /// Note : path.length must be equal to 2 with path[0] = tokenA and path[1] = tokenB
    /// @param amount The amount of tokenA to invest
    /// @param swapAmountIn The amount of tokenA to swap for tokenB
    /// @param path An array of the two paired token addresses
    /// @param uniswapRouter The uniswapV2 router to be used for swap and liquidity addition
    function _swapAndAddLiquidity(
        uint256 amount,
        uint256 swapAmountIn,
        address[] memory path,
        IUniswapV2Router02 uniswapRouter
    ) private returns (uint256 mintedLpAmount) {
        uint256[] memory swappedAmounts = uniswapRouter.swapExactTokensForTokens(
            swapAmountIn,
            1,
            path,
            address(this),
            block.timestamp
        );

        (, , mintedLpAmount) = uniswapRouter.addLiquidity(
            path[0],
            path[1],
            amount - swappedAmounts[0],
            swappedAmounts[1],
            1,
            1,
            address(this),
            block.timestamp
        );
    }

    /// @dev Calculate the optimal amount of tokenA to swap in order
    ///         to obtain the same market value of tokenB after the trade
    ///         in order to add as many tokensA and tokensB as possible
    ///         to the liquidity so that as few as possible remain.
    /// @param investmentA The total amount of tokenA to invest
    function _getOptimalSwapAmount(
        uint256 investmentA,
        uint256 reserveA,
        uint256 reserveB,
        IUniswapV2Router02 router
    ) private pure returns (uint256 swapAmount) {
        require(reserveA > 1000, "BLVO: PAIR_RESERVE_TOO_LOW");
        require(reserveB > 1000, "BLVO: PAIR_RESERVE_TOO_LOW");

        // The initial plan is to swap half of tokenA total amount to add liquidity
        uint256 halfInvestment = investmentA / 2;

        // Get the tokenB output for swapping tokenA (with the given reserves)
        uint256 nominator = router.getAmountOut(halfInvestment, reserveA, reserveB);

        // Get the amount of reserveB token representing equivalent value after swapping
        // tokenA for tokenB (previous operation).
        uint256 denominator = router.quote(halfInvestment, reserveA + halfInvestment, reserveB - nominator);

        // Equivalent of the simplification of a quadratic equation (ax² + bx + c = 0)
        // See : "optimal swap amount" in readme
        swapAmount = investmentA - Babylonian.sqrt((halfInvestment * halfInvestment * nominator) / denominator);
    }
}

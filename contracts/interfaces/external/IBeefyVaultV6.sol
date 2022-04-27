// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.11;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

interface IBeefyVaultV6 is IERC20 {
    function want() external view returns (IUniswapV2Pair);

    function deposit(uint256 _amount) external;
}

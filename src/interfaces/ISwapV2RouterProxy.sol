// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISwapV2RouterProxy {
    function swapExactHBARForTokens(bytes calldata path, address recipient, uint256 deadline, uint256 amountOutMinimum)
        external
        payable
        returns (uint256 amountOut);

    function swapHBARForExactTokens(
        bytes calldata path,
        address recipient,
        uint256 deadline,
        uint256 amountOut,
        uint256 amountInMaximum
    ) external payable returns (uint256 amountIn);

    function swapExactTokensForTokens(
        address tokenIn,
        uint256 amountIn,
        bytes calldata path,
        address recipient,
        uint256 deadline,
        uint256 amountOutMinimum
    ) external returns (uint256 amountOut);

    function swapTokensForExactTokens(
        address tokenIn,
        uint256 amountInMaximum,
        bytes calldata path,
        address recipient,
        uint256 deadline,
        uint256 amountOut
    ) external returns (uint256 amountIn);

    function swapExactTokensForHBAR(
        address tokenIn,
        uint256 amountIn,
        bytes calldata path,
        address recipient,
        uint256 deadline,
        uint256 amountOutMinimum
    ) external returns (uint256 amountOut);

    function swapTokensForExactHBAR(
        address tokenIn,
        uint256 amountInMaximum,
        bytes calldata path,
        address recipient,
        uint256 deadline,
        uint256 amountOut
    ) external returns (uint256 amountIn);
}

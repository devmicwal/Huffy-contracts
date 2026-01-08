// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {Treasury} from "../Treasury.sol";

/**
 * @title MockRelay
 * @notice Mock Relay contract for testing Treasury integration
 */
contract MockRelay {
    Treasury public treasury;

    constructor(address payable _treasury) {
        require(_treasury != address(0), "MockRelay: Invalid treasury");
        treasury = Treasury(_treasury);
    }

    function executeBuybackAndBurn(
        address tokenIn,
        bytes calldata pathToQuote,
        bytes calldata pathQuoteToHtk,
        uint256 amountIn,
        uint256 minQuoteOut,
        uint256 minAmountOut,
        uint256 maxPrice,
        uint256 deadline
    ) external returns (uint256) {
        return treasury.executeBuybackAndBurn(
            tokenIn, pathToQuote, pathQuoteToHtk, amountIn, minQuoteOut, minAmountOut, maxPrice, deadline
        );
    }

    function executeSwap(
        ISwapAdapter.SwapKind kind,
        address tokenIn,
        address tokenOut,
        bytes calldata path,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountOutMin,
        uint256 deadline
    ) external returns (uint256) {
        return treasury.executeSwap(kind, tokenIn, tokenOut, path, amountIn, amountOut, amountOutMin, deadline);
    }
}

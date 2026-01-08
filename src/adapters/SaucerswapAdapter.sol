/* SPDX-License-Identifier: GPL-2.0-or-later */
pragma solidity ^0.8.20;

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {ISwapV2RouterProxy} from "../interfaces/ISwapV2RouterProxy.sol";
import {ISwapV1RouterProxy} from "../interfaces/ISwapV1RouterProxy.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IHederaTokenService {
    function associateToken(address account, address token) external returns (int64);
}

contract SaucerswapAdapter is ISwapAdapter, Ownable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error UnsupportedKind();

    ISwapV2RouterProxy public immutable v2Router;
    ISwapV1RouterProxy public immutable v1Router;

    event AdapterSwap(address indexed caller, SwapKind kind, uint256 amountIn, uint256 amountOut);

    address private constant HTS = address(0x167);

    constructor(address payable _v2Router, address payable _v1Router) Ownable(msg.sender) {
        if (_v2Router == address(0)) revert ZeroAddress();
        v2Router = ISwapV2RouterProxy(_v2Router);
        v1Router = ISwapV1RouterProxy(_v1Router);
    }

    function swap(SwapRequest calldata req)
        external
        payable
        override
        returns (uint256 amountInUsed, uint256 amountOutReceived)
    {
        // Check if path is V1 (ABI encoded address[], length divisible by 32) or V2 (packed bytes)
        // V2 path length is typically 20 + 3 + 20 = 43.
        // V1 path (abi encoded) starts with offset (32) + length (32) + data...
        bool isV1 = (req.path.length >= 64 && req.path.length % 32 == 0);

        if (isV1) {
            require(address(v1Router) != address(0), "V1 Router not set");
            address[] memory path = abi.decode(req.path, (address[]));
            uint256[] memory amounts;

            if (req.kind == SwapKind.ExactHBARForTokens) {
                amounts = v1Router.swapExactHBARForTokens{value: msg.value}(
                    req.amountOutMinimum, path, req.recipient, req.deadline
                );
                amountInUsed = amounts[0];
                amountOutReceived = amounts[amounts.length - 1];
                _sweepHBAR(req.recipient);
            } else if (req.kind == SwapKind.HBARForExactTokens) {
                amounts = v1Router.swapHBARForExactTokens{value: msg.value}(
                    req.amountOut, path, req.recipient, req.deadline
                );
                amountInUsed = amounts[0];
                amountOutReceived = amounts[amounts.length - 1];
                if (msg.value > amountInUsed) {
                     (bool success, ) = payable(msg.sender).call{value: msg.value - amountInUsed}("");
                     require(success, "Refund failed");
                }
                 _sweepHBAR(req.recipient);
            } else if (req.kind == SwapKind.ExactTokensForTokens) {
                IERC20(req.tokenIn).safeTransferFrom(msg.sender, address(this), req.amountIn);
                IERC20(req.tokenIn).forceApprove(address(v1Router), req.amountIn);

                amounts = v1Router.swapExactTokensForTokens(
                    req.amountIn, req.amountOutMinimum, path, req.recipient, req.deadline
                );

                IERC20(req.tokenIn).forceApprove(address(v1Router), 0);

                amountInUsed = amounts[0];
                amountOutReceived = amounts[amounts.length - 1];
            } else if (req.kind == SwapKind.TokensForExactTokens) {
                IERC20(req.tokenIn).safeTransferFrom(msg.sender, address(this), req.amountInMaximum);
                IERC20(req.tokenIn).forceApprove(address(v1Router), req.amountInMaximum);

                amounts = v1Router.swapTokensForExactTokens(
                    req.amountOut, req.amountInMaximum, path, req.recipient, req.deadline
                );

                amountInUsed = amounts[0];
                amountOutReceived = amounts[amounts.length - 1];

                if (req.amountInMaximum > amountInUsed) {
                    IERC20(req.tokenIn).safeTransfer(msg.sender, req.amountInMaximum - amountInUsed);
                }
                IERC20(req.tokenIn).forceApprove(address(v1Router), 0);
            } else if (req.kind == SwapKind.ExactTokensForHBAR) {
                IERC20(req.tokenIn).safeTransferFrom(msg.sender, address(this), req.amountIn);
                IERC20(req.tokenIn).forceApprove(address(v1Router), req.amountIn);

                amounts = v1Router.swapExactTokensForHBAR(
                    req.amountIn, req.amountOutMinimum, path, req.recipient, req.deadline
                );

                IERC20(req.tokenIn).forceApprove(address(v1Router), 0);

                amountInUsed = amounts[0];
                amountOutReceived = amounts[amounts.length - 1];
            } else if (req.kind == SwapKind.TokensForExactHBAR) {
                IERC20(req.tokenIn).safeTransferFrom(msg.sender, address(this), req.amountInMaximum);
                IERC20(req.tokenIn).forceApprove(address(v1Router), req.amountInMaximum);

                amounts = v1Router.swapTokensForExactHBAR(
                    req.amountOut, req.amountInMaximum, path, req.recipient, req.deadline
                );

                amountInUsed = amounts[0];
                amountOutReceived = amounts[amounts.length - 1];

                if (req.amountInMaximum > amountInUsed) {
                    IERC20(req.tokenIn).safeTransfer(msg.sender, req.amountInMaximum - amountInUsed);
                }
                IERC20(req.tokenIn).forceApprove(address(v1Router), 0);
            } else {
                revert UnsupportedKind();
            }
        } else {
            // V2 SWAP
            if (req.kind == SwapKind.ExactHBARForTokens) {
                uint256 outAmt = v2Router.swapExactHBARForTokens{value: msg.value}(
                    req.path, req.recipient, req.deadline, req.amountOutMinimum
                );
                amountInUsed = msg.value;
                amountOutReceived = outAmt;
                _sweepHBAR(req.recipient);
            } else if (req.kind == SwapKind.HBARForExactTokens) {
                uint256 inAmt = v2Router.swapHBARForExactTokens{value: msg.value}(
                    req.path, req.recipient, req.deadline, req.amountOut, req.amountInMaximum
                );
                amountInUsed = inAmt;
                amountOutReceived = req.amountOut;
                _sweepHBAR(req.recipient);
            } else if (req.kind == SwapKind.ExactTokensForTokens) {
                IERC20 t = IERC20(req.tokenIn);
                t.safeTransferFrom(msg.sender, address(this), req.amountIn);
                t.forceApprove(address(v2Router), 0);
                t.forceApprove(address(v2Router), req.amountIn);

                uint256 outAmt2 = v2Router.swapExactTokensForTokens(
                    req.tokenIn, req.amountIn, req.path, req.recipient, req.deadline, req.amountOutMinimum
                );

                t.forceApprove(address(v2Router), 0);

                amountInUsed = req.amountIn;
                amountOutReceived = outAmt2;
            } else if (req.kind == SwapKind.TokensForExactTokens) {
                IERC20 t2 = IERC20(req.tokenIn);
                t2.safeTransferFrom(msg.sender, address(this), req.amountInMaximum);
                t2.forceApprove(address(v2Router), 0);
                t2.forceApprove(address(v2Router), req.amountInMaximum);

                uint256 inAmt2 = v2Router.swapTokensForExactTokens(
                    req.tokenIn, req.amountInMaximum, req.path, req.recipient, req.deadline, req.amountOut
                );

                if (req.amountInMaximum > inAmt2) {
                    t2.safeTransfer(msg.sender, req.amountInMaximum - inAmt2);
                }
                t2.forceApprove(address(v2Router), 0);

                amountInUsed = inAmt2;
                amountOutReceived = req.amountOut;
            } else if (req.kind == SwapKind.ExactTokensForHBAR) {
                IERC20 t3 = IERC20(req.tokenIn);
                t3.safeTransferFrom(msg.sender, address(this), req.amountIn);
                t3.forceApprove(address(v2Router), 0);
                t3.forceApprove(address(v2Router), req.amountIn);

                uint256 outHBAR = v2Router.swapExactTokensForHBAR(
                    req.tokenIn, req.amountIn, req.path, req.recipient, req.deadline, req.amountOutMinimum
                );

                t3.forceApprove(address(v2Router), 0);

                amountInUsed = req.amountIn;
                amountOutReceived = outHBAR;
            } else if (req.kind == SwapKind.TokensForExactHBAR) {
                IERC20 t4 = IERC20(req.tokenIn);
                t4.safeTransferFrom(msg.sender, address(this), req.amountInMaximum);
                t4.forceApprove(address(v2Router), 0);
                t4.forceApprove(address(v2Router), req.amountInMaximum);

                uint256 inAmt3 = v2Router.swapTokensForExactHBAR(
                    req.tokenIn, req.amountInMaximum, req.path, req.recipient, req.deadline, req.amountOut
                );

                if (req.amountInMaximum > inAmt3) {
                    t4.safeTransfer(msg.sender, req.amountInMaximum - inAmt3);
                }
                t4.forceApprove(address(v2Router), 0);

                amountInUsed = inAmt3;
                amountOutReceived = req.amountOut;
            } else {
                revert UnsupportedKind();
            }
        }

        emit AdapterSwap(msg.sender, req.kind, amountInUsed, amountOutReceived);
    }

    function _sweepHBAR(address recipient) private {
        uint256 bal = address(this).balance;
        if (bal == 0 || recipient == address(0)) return;
        (bool ok,) = payable(recipient).call{value: bal}("");
        require(ok, "Adapter: sweep HBAR failed");
    }

    // --------------------
    // Hedera: association
    // --------------------
    event AdapterAssociated(address indexed token);
    event AdapterBatchAssociated(uint256 count);

    function associateAdapterToToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        int64 rc = IHederaTokenService(HTS).associateToken(address(this), token);
        require(rc == 22 || rc == 0, "HTS associate failed"); // 22 = ALREADY_ASSOCIATED
        emit AdapterAssociated(token);
    }

    function batchAssociateAdapterToTokens(address[] calldata tokens) external onlyOwner {
        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; i++) {
            address token = tokens[i];
            if (token == address(0)) revert ZeroAddress();
            int64 rc = IHederaTokenService(HTS).associateToken(address(this), token);
            require(rc == 22 || rc == 0, "HTS associate failed");
            emit AdapterAssociated(token);
        }
        emit AdapterBatchAssociated(n);
    }

    receive() external payable {}
}

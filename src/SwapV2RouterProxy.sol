/* SPDX-License-Identifier: GPL-2.0-or-later */
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}

interface IPeripheryPayments {
    function refundETH() external payable;
    function unwrapWHBAR(uint256 amountMinimum, address recipient) external payable;
}

interface IHederaTokenService {
    function associateToken(address account, address token) external returns (int64);
}

contract SwapV2RouterProxy is Ownable, ReentrancyGuard {
    address public immutable router;
    address public immutable WHBAR;

    address private constant HTS = address(0x167);

    event SwapExactHBARForTokens(
        address indexed sender, bytes path, address indexed recipient, uint256 amountInTinybar, uint256 amountOut
    );
    event SwapHBARForExactTokens(
        address indexed sender,
        bytes pathReversed,
        address indexed recipient,
        uint256 amountOut,
        uint256 amountInTinybar
    );
    event SwapExactTokensForTokens(
        address indexed sender,
        address indexed tokenIn,
        bytes path,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut
    );
    event SwapTokensForExactTokens(
        address indexed sender,
        address indexed tokenIn,
        bytes pathReversed,
        address indexed recipient,
        uint256 amountOut,
        uint256 amountIn
    );
    event SwapExactTokensForHBAR(
        address indexed sender,
        address indexed tokenIn,
        bytes pathToWHBAR,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOutTinybar
    );
    event SwapTokensForExactHBAR(
        address indexed sender,
        address indexed tokenIn,
        bytes pathReversedToWHBAR,
        address indexed recipient,
        uint256 amountOutTinybar,
        uint256 amountIn
    );
    event Associated(address indexed token);
    event BatchAssociated(uint256 count);

    error ZeroAddress();
    error DeadlinePassed();
    error InsufficientMsgValue();
    error TransferFailed();
    error ApproveFailed();
    error InvalidPathForUnwrap();

    constructor(address _router, address _whbar) Ownable(msg.sender) {
        if (_router == address(0) || _whbar == address(0)) revert ZeroAddress();
        router = _router;
        WHBAR = _whbar;
    }

    function swapExactHBARForTokens(bytes calldata path, address recipient, uint256 deadline, uint256 amountOutMinimum)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        amountOut = _swapExactHBARForTokens(path, recipient, deadline, amountOutMinimum);
    }

    function swapHBARForExactTokens(
        bytes calldata pathReversed,
        address recipient,
        uint256 deadline,
        uint256 amountOut,
        uint256 amountInMaximum
    ) external payable nonReentrant returns (uint256 amountIn) {
        amountIn = _swapHBARForExactTokens(pathReversed, recipient, deadline, amountOut, amountInMaximum);
    }

    function swapExactTokensForTokens(
        address tokenIn,
        uint256 amountIn,
        bytes calldata path,
        address recipient,
        uint256 deadline,
        uint256 amountOutMinimum
    ) external nonReentrant returns (uint256 amountOut) {
        amountOut = _swapExactTokensForTokens(tokenIn, amountIn, path, recipient, deadline, amountOutMinimum);
    }

    function swapTokensForExactTokens(
        address tokenIn,
        uint256 amountInMaximum,
        bytes calldata pathReversed,
        address recipient,
        uint256 deadline,
        uint256 amountOut
    ) external nonReentrant returns (uint256 amountIn) {
        amountIn = _swapTokensForExactTokens(tokenIn, amountInMaximum, pathReversed, recipient, deadline, amountOut);
    }

    function swapExactTokensForHBAR(
        address tokenIn,
        uint256 amountIn,
        bytes calldata pathToWHBAR,
        address finalRecipient,
        uint256 deadline,
        uint256 minTinybar
    ) external nonReentrant returns (uint256 amountOutTinybar) {
        amountOutTinybar = _swapExactTokensForHBAR(tokenIn, amountIn, pathToWHBAR, finalRecipient, deadline, minTinybar);
    }

    function swapTokensForExactHBAR(
        address tokenIn,
        uint256 amountInMaximum,
        bytes calldata pathReversedToWHBAR,
        address finalRecipient,
        uint256 deadline,
        uint256 amountOutTinybar
    ) external nonReentrant returns (uint256 amountIn) {
        amountIn = _swapTokensForExactHBAR(
            tokenIn, amountInMaximum, pathReversedToWHBAR, finalRecipient, deadline, amountOutTinybar
        );
    }

    function associateProxyToToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        int64 rc = IHederaTokenService(HTS).associateToken(address(this), token);
        require(rc == 22 || rc == 0, "HTS associate failed");
        emit Associated(token);
    }

    function batchAssociateProxyToTokens(address[] calldata tokens) external onlyOwner {
        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; i++) {
            address token = tokens[i];
            if (token == address(0)) revert ZeroAddress();
            int64 rc = IHederaTokenService(HTS).associateToken(address(this), token);
            require(rc == 22 || rc == 0, "HTS associate failed");
            emit Associated(token);
        }
        emit BatchAssociated(n);
    }

    receive() external payable {}

    function _swapExactHBARForTokens(bytes memory path, address recipient, uint256 deadline, uint256 amountOutMinimum)
        internal
        returns (uint256 amountOut)
    {
        _checkDeadline(deadline);

        ISwapRouter.ExactInputParams memory p = ISwapRouter.ExactInputParams({
            path: path,
            recipient: recipient,
            deadline: deadline,
            amountIn: msg.value,
            amountOutMinimum: amountOutMinimum
        });

        amountOut = ISwapRouter(router).exactInput{value: msg.value}(p);

        IPeripheryPayments(router).refundETH();
        _sweepHBAR(payable(msg.sender));

        emit SwapExactHBARForTokens(msg.sender, path, recipient, msg.value, amountOut);
    }

    function _swapHBARForExactTokens(
        bytes memory pathReversed,
        address recipient,
        uint256 deadline,
        uint256 amountOut,
        uint256 amountInMaximum
    ) internal returns (uint256 amountIn) {
        _checkDeadline(deadline);

        ISwapRouter.ExactOutputParams memory p = ISwapRouter.ExactOutputParams({
            path: pathReversed,
            recipient: recipient,
            deadline: deadline,
            amountOut: amountOut,
            amountInMaximum: amountInMaximum
        });

        amountIn = ISwapRouter(router).exactOutput{value: msg.value}(p);

        IPeripheryPayments(router).refundETH();
        _sweepHBAR(payable(msg.sender));

        emit SwapHBARForExactTokens(msg.sender, pathReversed, recipient, amountOut, amountIn);
    }

    function _swapExactTokensForTokens(
        address tokenIn,
        uint256 amountIn,
        bytes memory path,
        address recipient,
        uint256 deadline,
        uint256 amountOutMinimum
    ) internal returns (uint256 amountOut) {
        _checkDeadline(deadline);

        _pullToken(tokenIn, msg.sender, amountIn);
        _approve(tokenIn, router, amountIn);

        ISwapRouter.ExactInputParams memory p = ISwapRouter.ExactInputParams({
            path: path, recipient: recipient, deadline: deadline, amountIn: amountIn, amountOutMinimum: amountOutMinimum
        });

        amountOut = ISwapRouter(router).exactInput(p);

        _approve(tokenIn, router, 0);

        emit SwapExactTokensForTokens(msg.sender, tokenIn, path, recipient, amountIn, amountOut);
    }

    function _swapTokensForExactTokens(
        address tokenIn,
        uint256 amountInMaximum,
        bytes memory pathReversed,
        address recipient,
        uint256 deadline,
        uint256 amountOut
    ) internal returns (uint256 amountIn) {
        _checkDeadline(deadline);

        _pullToken(tokenIn, msg.sender, amountInMaximum);
        _approve(tokenIn, router, amountInMaximum);

        ISwapRouter.ExactOutputParams memory p = ISwapRouter.ExactOutputParams({
            path: pathReversed,
            recipient: recipient,
            deadline: deadline,
            amountOut: amountOut,
            amountInMaximum: amountInMaximum
        });

        amountIn = ISwapRouter(router).exactOutput(p);

        if (amountInMaximum > amountIn) {
            _safeTokenTransfer(tokenIn, msg.sender, amountInMaximum - amountIn);
        }
        _approve(tokenIn, router, 0);

        emit SwapTokensForExactTokens(msg.sender, tokenIn, pathReversed, recipient, amountOut, amountIn);
    }

    function _swapExactTokensForHBAR(
        address tokenIn,
        uint256 amountIn,
        bytes memory pathToWHBAR,
        address finalRecipient,
        uint256 deadline,
        uint256 minTinybar
    ) internal returns (uint256 amountOutTinybar) {
        _checkDeadline(deadline);
        if (_lastTokenInPath(pathToWHBAR) != WHBAR) revert InvalidPathForUnwrap();

        _pullToken(tokenIn, msg.sender, amountIn);
        _approve(tokenIn, router, amountIn);

        ISwapRouter.ExactInputParams memory p = ISwapRouter.ExactInputParams({
            path: pathToWHBAR, recipient: router, deadline: deadline, amountIn: amountIn, amountOutMinimum: minTinybar
        });

        amountOutTinybar = ISwapRouter(router).exactInput(p);

        IPeripheryPayments(router).unwrapWHBAR(0, finalRecipient);

        _approve(tokenIn, router, 0);

        emit SwapExactTokensForHBAR(msg.sender, tokenIn, pathToWHBAR, finalRecipient, amountIn, amountOutTinybar);
    }

    function _swapTokensForExactHBAR(
        address tokenIn,
        uint256 amountInMaximum,
        bytes memory pathReversedToWHBAR,
        address finalRecipient,
        uint256 deadline,
        uint256 amountOutTinybar
    ) internal returns (uint256 amountIn) {
        _checkDeadline(deadline);
        if (_firstTokenInPath(pathReversedToWHBAR) != WHBAR) revert InvalidPathForUnwrap();

        _pullToken(tokenIn, msg.sender, amountInMaximum);
        _approve(tokenIn, router, amountInMaximum);

        ISwapRouter.ExactOutputParams memory p = ISwapRouter.ExactOutputParams({
            path: pathReversedToWHBAR,
            recipient: router,
            deadline: deadline,
            amountOut: amountOutTinybar,
            amountInMaximum: amountInMaximum
        });

        amountIn = ISwapRouter(router).exactOutput(p);

        IPeripheryPayments(router).unwrapWHBAR(0, finalRecipient);

        if (amountInMaximum > amountIn) {
            _safeTokenTransfer(tokenIn, msg.sender, amountInMaximum - amountIn);
        }
        _approve(tokenIn, router, 0);

        emit SwapTokensForExactHBAR(
            msg.sender, tokenIn, pathReversedToWHBAR, finalRecipient, amountOutTinybar, amountIn
        );
    }

    function _pullToken(address token, address from, uint256 amount) internal {
        if (amount == 0) return;
        bool ok = IERC20(token).transferFrom(from, address(this), amount);
        if (!ok) revert TransferFailed();
    }

    function _approve(address token, address spender, uint256 amount) internal {
        uint256 curr = IERC20(token).allowance(address(this), spender);
        if (curr != 0) {
            require(IERC20(token).approve(spender, 0), "approve reset failed");
        }
        bool ok = IERC20(token).approve(spender, amount);
        if (!ok) revert ApproveFailed();
    }

    function _safeTokenTransfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        bool ok = IERC20(token).transfer(to, amount);
        if (!ok) revert TransferFailed();
    }

    function _sweepHBAR(address payable to) internal {
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool s,) = to.call{value: bal}("");
        require(s, "HBAR transfer failed");
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert DeadlinePassed();
    }

    function _firstTokenInPath(bytes memory path) internal pure returns (address token) {
        require(path.length >= 20, "path short");
        assembly {
            token := shr(96, mload(add(path, 32)))
        }
    }

    function _lastTokenInPath(bytes memory path) internal pure returns (address token) {
        require(path.length >= 20, "path short");
        uint256 lastOffset = 32 + (path.length - 20);
        assembly {
            token := shr(96, mload(add(path, lastOffset)))
        }
    }
}

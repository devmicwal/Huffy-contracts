// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

interface ISwapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IWHBAR is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface IHederaTokenService {
    function associateToken(address account, address token) external returns (int64);
}

contract SwapV1RouterProxy is Ownable {
    using SafeERC20 for IERC20;

    address public immutable router;
    IWHBAR public immutable WHBAR;
    address private constant HTS = address(0x167);

    error ZeroAddress();
    error RefundFailed();
    error PathMismatch();

    event SwapExactHBARForTokens(
        address indexed sender, address[] path, address indexed recipient, uint256 amountInTinybar, uint256 amountOut
    );
    event SwapHBARForExactTokens(
        address indexed sender, address[] path, address indexed recipient, uint256 amountOut, uint256 amountInTinybar
    );
    event SwapExactTokensForTokens(
        address indexed sender,
        address indexed tokenIn,
        address[] path,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut
    );
    event SwapTokensForExactTokens(
        address indexed sender,
        address indexed tokenIn,
        address[] path,
        address indexed recipient,
        uint256 amountOut,
        uint256 amountIn
    );
    event SwapExactTokensForHBAR(
        address indexed sender,
        address indexed tokenIn,
        address[] path,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOutTinybar
    );
    event SwapTokensForExactHBAR(
        address indexed sender,
        address indexed tokenIn,
        address[] path,
        address indexed recipient,
        uint256 amountOutTinybar,
        uint256 amountIn
    );
    event Associated(address indexed token);

    constructor(address _router, address _whbar) Ownable(msg.sender) {
        if (_router == address(0) || _whbar == address(0)) revert ZeroAddress();
        router = _router;
        WHBAR = IWHBAR(_whbar);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[0]).forceApprove(address(router), amountIn);

        amounts = ISwapRouter(router).swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline);

        IERC20(path[0]).forceApprove(address(router), 0);

        emit SwapExactTokensForTokens(msg.sender, path[0], path, to, amountIn, amounts[amounts.length - 1]);
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountInMax);
        IERC20(path[0]).forceApprove(address(router), amountInMax);

        amounts = ISwapRouter(router).swapTokensForExactTokens(amountOut, amountInMax, path, to, deadline);

        if (amountInMax > amounts[0]) {
            IERC20(path[0]).safeTransfer(msg.sender, amountInMax - amounts[0]);
        }
        IERC20(path[0]).forceApprove(address(router), 0);

        emit SwapTokensForExactTokens(msg.sender, path[0], path, to, amountOut, amounts[0]);
    }

    function swapExactHBARForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts)
    {
        if (path[0] != address(WHBAR)) revert PathMismatch();
        amounts = ISwapRouter(router).swapExactETHForTokens{value: msg.value}(amountOutMin, path, to, deadline);

        emit SwapExactHBARForTokens(msg.sender, path, to, msg.value, amounts[amounts.length - 1]);
    }

    function swapTokensForExactHBAR(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        if (path[path.length - 1] != address(WHBAR)) revert PathMismatch();

        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountInMax);
        IERC20(path[0]).forceApprove(address(router), amountInMax);

        amounts = ISwapRouter(router).swapTokensForExactETH(amountOut, amountInMax, path, to, deadline);

        if (amountInMax > amounts[0]) {
            IERC20(path[0]).safeTransfer(msg.sender, amountInMax - amounts[0]);
        }
        IERC20(path[0]).forceApprove(address(router), 0);

        emit SwapTokensForExactHBAR(msg.sender, path[0], path, to, amountOut, amounts[0]);
    }

    function swapExactTokensForHBAR(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        if (path[path.length - 1] != address(WHBAR)) revert PathMismatch();

        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[0]).forceApprove(address(router), amountIn);

        amounts = ISwapRouter(router).swapExactTokensForETH(amountIn, amountOutMin, path, to, deadline);

        IERC20(path[0]).forceApprove(address(router), 0);

        emit SwapExactTokensForHBAR(msg.sender, path[0], path, to, amountIn, amounts[amounts.length - 1]);
    }

    function swapHBARForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts)
    {
        if (path[0] != address(WHBAR)) revert PathMismatch();
        amounts = ISwapRouter(router).swapETHForExactTokens{value: msg.value}(amountOut, path, to, deadline);

        uint256 amountInUsed = amounts[0];
        if (msg.value > amountInUsed) {
            (bool success,) = payable(msg.sender).call{value: msg.value - amountInUsed}("");
            if (!success) revert RefundFailed();
        }

        emit SwapHBARForExactTokens(msg.sender, path, to, amountOut, amounts[0]);
    }

    function associateProxyToToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        int64 rc = IHederaTokenService(HTS).associateToken(address(this), token);
        require(rc == 22 || rc == 0 || rc == 195, "HTS associate failed");
        emit Associated(token);
    }

    receive() external payable {}
}

// SPDX-License-Identifier: MIT
// File: contracts/Treasury.sol
pragma solidity ^0.8.20;

import {AccessControl} from "../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {SafeERC20, IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ISwapAdapter} from "./interfaces/ISwapAdapter.sol";

// Hedera HTS (association)
interface IHederaTokenService {
    function associateToken(address account, address token) external returns (int64);
}

contract Treasury is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant RELAY_ROLE = keccak256("RELAY_ROLE");
    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE");

    // Immutable config
    address public immutable HTK_TOKEN;
    address public immutable QUOTE_TOKEN; // e.g. USDC used for buybacks
    ISwapAdapter public adapter;
    address public whbarToken;
    address public burnSink;

    // HTS precompile
    address private constant HTS = address(0x167);

    // Events
    event Deposited(address indexed token, address indexed depositor, uint256 amount, uint256 timestamp);
    event Withdrawn(
        address indexed token, address indexed recipient, uint256 amount, address indexed initiator, uint256 timestamp
    );
    event BuybackExecuted(
        address indexed tokenIn, uint256 amountIn, uint256 htkReceived, address indexed initiator, uint256 timestamp
    );
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed initiator,
        uint256 timestamp
    );
    event Burned(uint256 amount, address indexed initiator, uint256 timestamp);
    event RelayUpdated(address indexed oldRelay, address indexed newRelay, uint256 timestamp);
    event AdapterUpdated(address indexed oldAdapter, address indexed newAdapter, uint256 timestamp);
    event WhbarTokenUpdated(address indexed oldWhbar, address indexed newWhbar, uint256 timestamp);
    event BurnSinkUpdated(address indexed oldSink, address indexed newSink, uint256 timestamp);

    // Association
    event TreasuryAssociated(address indexed token);
    event TreasuryBatchAssociated(uint256 count);

    constructor(
        address _htkToken,
        address _quoteToken,
        address _adapter,
        address _admin,
        address _relay,
        address _burnSink,
        address _whbarToken
    ) {
        require(_htkToken != address(0), "Treasury: Invalid HTK token");
        require(_quoteToken != address(0), "Treasury: Invalid quote token");
        require(_quoteToken != _htkToken, "Treasury: quote token equals HTK");
        require(_adapter != address(0), "Treasury: Invalid adapter");
        require(_admin != address(0), "Treasury: Invalid admin");
        require(_relay != address(0), "Treasury: Invalid relay");
        require(_burnSink != address(0), "Treasury: Invalid burn sink");
        require(_whbarToken != address(0), "Treasury: Invalid WHBAR");

        HTK_TOKEN = _htkToken;
        QUOTE_TOKEN = _quoteToken;
        adapter = ISwapAdapter(_adapter);
        burnSink = _burnSink;
        whbarToken = _whbarToken;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(DAO_ROLE, _admin);
        _grantRole(RELAY_ROLE, _relay);
    }

    // ------------ User-facing ops ------------

    function deposit(address token, uint256 amount) external nonReentrant {
        require(token != address(0), "Treasury: Invalid token");
        require(amount > 0, "Treasury: Zero amount");
        // Note: Treasury must be associated with an HTS token before it can receive transfers
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(token, msg.sender, amount, block.timestamp);
    }

    function withdraw(address token, address recipient, uint256 amount) external onlyRole(DAO_ROLE) nonReentrant {
        require(token != address(0), "Treasury: Invalid token");
        require(recipient != address(0), "Treasury: Invalid recipient");
        require(amount > 0, "Treasury: Zero amount");
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= amount, "Treasury: Insufficient balance");
        IERC20(token).safeTransfer(recipient, amount);
        emit Withdrawn(token, recipient, amount, msg.sender, block.timestamp);
    }

    // ------------ Buyback & burn (ExactTokensForTokens) ------------

    function executeBuybackAndBurn(
        address tokenToSell,
        bytes calldata pathToQuote,
        bytes calldata pathQuoteToHtk,
        uint256 amountIn,
        uint256 minQuoteOut,
        uint256 minHtkOut,
        uint256 maxHtkPriceD18,
        uint256 deadline
    ) external payable onlyRole(RELAY_ROLE) nonReentrant returns (uint256 burnedAmount) {
        address quote = QUOTE_TOKEN;
        bool isHbar = tokenToSell == whbarToken;
        require(tokenToSell != HTK_TOKEN, "Treasury: Cannot swap HTK for HTK");
        require(amountIn > 0, "Treasury: Zero amount");
        require(minHtkOut > 0, "Treasury: Zero minOut");
        require(deadline >= block.timestamp, "Treasury: Expired deadline");

        // Validate pathQuoteToHtk
        require(pathQuoteToHtk.length > 0, "Treasury: Invalid quote to HTK path");
        (address quoteStart, address quoteEnd) = _extractPathEndpoints(pathQuoteToHtk);
        require(quoteStart == quote, "Treasury: quote path start mismatch");
        require(quoteEnd == HTK_TOKEN, "Treasury: quote path end mismatch");

        if (isHbar) {
            require(address(this).balance >= amountIn, "Treasury: Insufficient balance");
        } else {
            require(IERC20(tokenToSell).balanceOf(address(this)) >= amountIn, "Treasury: Insufficient balance");
        }
        uint256 quoteAmount;
        if (isHbar) {
            require(pathToQuote.length > 0, "Treasury: Path required");
            (address startNative, address endNative) = _extractPathEndpoints(pathToQuote);
            require(startNative == whbarToken, "Treasury: Path must start with WHBAR");
            require(endNative == quote, "Treasury: Path must end in quote");
            ISwapAdapter.SwapRequest memory nativeToQuote = ISwapAdapter.SwapRequest({
                kind: ISwapAdapter.SwapKind.ExactHBARForTokens,
                tokenIn: address(0),
                path: pathToQuote,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn,
                amountOut: 0,
                amountInMaximum: amountIn,
                amountOutMinimum: minQuoteOut
            });
            (, quoteAmount) = adapter.swap{value: amountIn}(nativeToQuote);
            require(quoteAmount >= minQuoteOut, "Treasury: Insufficient quote out");
        } else if (tokenToSell == quote) {
            // direct quote -> HTK, pathToQuote ignored
            quoteAmount = amountIn;
        } else {
            require(pathToQuote.length > 0, "Treasury: Path required");
            (address start, address end) = _extractPathEndpoints(pathToQuote);
            require(start == tokenToSell, "Treasury: Path start mismatch");
            require(end == quote, "Treasury: Path must end in quote");
            IERC20(tokenToSell).forceApprove(address(adapter), 0);
            IERC20(tokenToSell).forceApprove(address(adapter), amountIn);
            ISwapAdapter.SwapRequest memory toQuote = ISwapAdapter.SwapRequest({
                kind: ISwapAdapter.SwapKind.ExactTokensForTokens,
                tokenIn: tokenToSell,
                path: pathToQuote,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn,
                amountOut: 0,
                amountInMaximum: amountIn,
                amountOutMinimum: minQuoteOut
            });
            (, quoteAmount) = adapter.swap(toQuote);
            require(quoteAmount >= minQuoteOut, "Treasury: Insufficient quote out");
        }
        // Price guard (skip if maxHtkPriceD18 == type(uint256).max)
        if (maxHtkPriceD18 != type(uint256).max) {
            uint8 quoteDec = IERC20Metadata(quote).decimals();
            uint8 htkDec = IERC20Metadata(HTK_TOKEN).decimals();
            uint256 quote18 =
                quoteDec <= 18 ? quoteAmount * (10 ** (18 - quoteDec)) : quoteAmount / (10 ** (quoteDec - 18));
            uint256 htkMin18 = htkDec <= 18 ? minHtkOut * (10 ** (18 - htkDec)) : minHtkOut / (10 ** (htkDec - 18));
            require(htkMin18 > 0, "Treasury: minOut underflow");
            uint256 priceD18 = (quote18 * 1e18) / htkMin18;
            require(priceD18 <= maxHtkPriceD18, "Treasury: HTK price too high");
        }
        // Swap quote -> HTK using provided path (supports both V1 and V2)
        IERC20(quote).forceApprove(address(adapter), 0);
        IERC20(quote).forceApprove(address(adapter), quoteAmount);
        ISwapAdapter.SwapRequest memory toHtk = ISwapAdapter.SwapRequest({
            kind: ISwapAdapter.SwapKind.ExactTokensForTokens,
            tokenIn: quote,
            path: pathQuoteToHtk,
            recipient: address(this),
            deadline: deadline,
            amountIn: quoteAmount,
            amountOut: 0,
            amountInMaximum: quoteAmount,
            amountOutMinimum: minHtkOut
        });
        (, uint256 htkReceived) = adapter.swap(toHtk);
        require(htkReceived >= minHtkOut, "Treasury: Insufficient output");
        emit BuybackExecuted(tokenToSell, amountIn, htkReceived, msg.sender, block.timestamp);
        burnedAmount = _burn(htkReceived);
        return burnedAmount;
    }

    // ------------ Generic swaps ------------

    // Generic swaps (token-token, token-HBAR, HBAR-token)
    function executeSwap(
        ISwapAdapter.SwapKind kind,
        address tokenIn,
        address tokenOut,
        bytes calldata path,
        uint256 amountIn, // exact-in or max-in (for exact-out)
        uint256 amountOut, // expected out (for exact-out flows)
        uint256 amountOutMin, // min out (for exact-in flows)
        uint256 deadline
    ) external payable onlyRole(RELAY_ROLE) nonReentrant returns (uint256 amountReceived) {
        require(deadline >= block.timestamp, "Treasury: Expired deadline");
        require(path.length > 0, "Treasury: Invalid path");

        // Ignore msg.value for token-in flows to avoid accidental funding
        if (
            kind == ISwapAdapter.SwapKind.ExactTokensForTokens || kind == ISwapAdapter.SwapKind.TokensForExactTokens
                || kind == ISwapAdapter.SwapKind.ExactTokensForHBAR || kind == ISwapAdapter.SwapKind.TokensForExactHBAR
        ) {
            require(msg.value == 0, "Treasury: Unexpected value");
        }

        // HBAR-in flows (financed from Treasury balance; msg.value must be 0)
        if (kind == ISwapAdapter.SwapKind.ExactHBARForTokens) {
            require(tokenOut != address(0), "Treasury: Invalid tokenOut");
            require(msg.value == 0, "Treasury: Unexpected value");
            uint256 amountInEffective = amountIn;
            require(amountInEffective > 0, "Treasury: Zero amount");
            require(address(this).balance >= amountInEffective, "Treasury: Insufficient balance");
            require(amountOutMin > 0, "Treasury: Zero minOut");

            ISwapAdapter.SwapRequest memory hbarExactInRequest = ISwapAdapter.SwapRequest({
                kind: kind,
                tokenIn: address(0),
                path: path,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountInEffective,
                amountOut: 0,
                amountInMaximum: amountInEffective,
                amountOutMinimum: amountOutMin
            });

            (, amountReceived) = adapter.swap{value: amountInEffective}(hbarExactInRequest);
            require(amountReceived >= amountOutMin, "Treasury: Insufficient output");

            emit SwapExecuted(address(0), tokenOut, amountInEffective, amountReceived, msg.sender, block.timestamp);
            return amountReceived;
        }

        if (kind == ISwapAdapter.SwapKind.HBARForExactTokens) {
            require(tokenOut != address(0), "Treasury: Invalid tokenOut");
            require(amountOut > 0, "Treasury: Zero amountOut");
            require(msg.value == 0, "Treasury: Unexpected value");
            uint256 amountInMaxEffective = amountIn;
            require(amountInMaxEffective > 0, "Treasury: Zero maxIn");
            require(address(this).balance >= amountInMaxEffective, "Treasury: Insufficient balance");

            ISwapAdapter.SwapRequest memory hbarExactOutRequest = ISwapAdapter.SwapRequest({
                kind: kind,
                tokenIn: address(0),
                path: path,
                recipient: address(this),
                deadline: deadline,
                amountIn: 0,
                amountOut: amountOut,
                amountInMaximum: amountInMaxEffective,
                amountOutMinimum: 0
            });

            (uint256 amountInUsedHBAR, uint256 amountOutReceivedHBAR) =
                adapter.swap{value: amountInMaxEffective}(hbarExactOutRequest);
            require(amountOutReceivedHBAR >= amountOut, "Treasury: Insufficient output");
            require(amountInUsedHBAR <= amountInMaxEffective, "Treasury: overspent");
            amountReceived = amountOutReceivedHBAR;

            emit SwapExecuted(address(0), tokenOut, amountInUsedHBAR, amountReceived, msg.sender, block.timestamp);
            return amountReceived;
        }

        // Token-in flows (token-token or token-HBAR)
        require(tokenIn != address(0), "Treasury: Invalid tokenIn");

        uint256 approveAmount;
        if (kind == ISwapAdapter.SwapKind.ExactTokensForTokens || kind == ISwapAdapter.SwapKind.ExactTokensForHBAR) {
            require(
                tokenOut != address(0) || kind == ISwapAdapter.SwapKind.ExactTokensForHBAR, "Treasury: Invalid tokenOut"
            );
            if (kind == ISwapAdapter.SwapKind.ExactTokensForTokens) {
                require(tokenIn != tokenOut, "Treasury: Same token");
            }
            require(amountIn > 0, "Treasury: Zero amount");
            require(amountOutMin > 0, "Treasury: Zero minOut");
            approveAmount = amountIn;
        } else if (
            kind == ISwapAdapter.SwapKind.TokensForExactTokens || kind == ISwapAdapter.SwapKind.TokensForExactHBAR
        ) {
            require(
                tokenOut != address(0) || kind == ISwapAdapter.SwapKind.TokensForExactHBAR, "Treasury: Invalid tokenOut"
            );
            if (kind == ISwapAdapter.SwapKind.TokensForExactTokens) {
                require(tokenIn != tokenOut, "Treasury: Same token");
            }
            require(amountIn > 0, "Treasury: Zero maxIn");
            require(amountOut > 0, "Treasury: Zero amountOut");
            approveAmount = amountIn;
        } else {
            revert("Treasury: Unsupported kind");
        }

        // Token balance check + approve
        require(IERC20(tokenIn).balanceOf(address(this)) >= approveAmount, "Treasury: Insufficient balance");
        IERC20(tokenIn).forceApprove(address(adapter), 0);
        IERC20(tokenIn).forceApprove(address(adapter), approveAmount);

        ISwapAdapter.SwapRequest memory request = ISwapAdapter.SwapRequest({
            kind: kind,
            tokenIn: tokenIn,
            path: path,
            recipient: address(this),
            deadline: deadline,
            amountIn: amountIn,
            amountOut: amountOut,
            amountInMaximum: amountIn,
            amountOutMinimum: amountOutMin
        });

        (uint256 amountInUsed, uint256 amountOutReceivedTokens) = adapter.swap(request);

        if (kind == ISwapAdapter.SwapKind.ExactTokensForTokens || kind == ISwapAdapter.SwapKind.ExactTokensForHBAR) {
            require(amountOutReceivedTokens >= amountOutMin, "Treasury: Insufficient output");
            amountReceived = amountOutReceivedTokens;
        } else {
            // TokensForExactTokens or TokensForExactHBAR
            require(amountOutReceivedTokens >= amountOut, "Treasury: Insufficient output");
            require(amountInUsed <= amountIn, "Treasury: overspent");
            amountReceived = amountOutReceivedTokens;
        }

        emit SwapExecuted(tokenIn, tokenOut, amountInUsed, amountReceived, msg.sender, block.timestamp);
        return amountReceived;
    }

    // ------------ Views ------------

    function getBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // ------------ Admin ------------

    function updateRelay(address oldRelay, address newRelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRelay != address(0), "Treasury: Invalid relay");
        require(oldRelay != newRelay, "Treasury: Same relay");
        _revokeRole(RELAY_ROLE, oldRelay);
        _grantRole(RELAY_ROLE, newRelay);
        emit RelayUpdated(oldRelay, newRelay, block.timestamp);
    }

    function setAdapter(address newAdapter) external onlyRole(DAO_ROLE) {
        require(newAdapter != address(0), "Treasury: Invalid adapter");
        address old = address(adapter);
        require(newAdapter != old, "Treasury: Same adapter");
        adapter = ISwapAdapter(newAdapter);
        emit AdapterUpdated(old, newAdapter, block.timestamp);
    }

    function setWhbarToken(address newWhbar) external onlyRole(DAO_ROLE) {
        require(newWhbar != address(0), "Treasury: Invalid WHBAR");
        address old = whbarToken;
        require(newWhbar != old, "Treasury: Same WHBAR");
        whbarToken = newWhbar;
        emit WhbarTokenUpdated(old, newWhbar, block.timestamp);
    }

    function setBurnSink(address newSink) external onlyRole(DAO_ROLE) {
        require(newSink != address(0), "Treasury: Invalid burn sink");
        address old = burnSink;
        require(newSink != old, "Treasury: Same burn sink");
        burnSink = newSink;
        emit BurnSinkUpdated(old, newSink, block.timestamp);
    }

    // ------------ Internal ------------

    function _burn(uint256 amount) private returns (uint256) {
        require(amount > 0, "Treasury: Zero burn amount");
        // Reminder: native HTS burn typically requires a role. Here we send to a dead address instead
        IERC20(HTK_TOKEN).safeTransfer(burnSink, amount);
        emit Burned(amount, msg.sender, block.timestamp);
        return amount;
    }

    function _extractPathEndpoints(bytes memory path) private pure returns (address start, address end) {
        if (path.length >= 43 && (path.length - 20) % 23 == 0) {
            start = _readAddress(path, 0);
            uint256 tokenCount = 1 + (path.length - 20) / 23;
            uint256 lastOffset = 23 * (tokenCount - 1);
            end = _readAddress(path, lastOffset);
            return (start, end);
        }
        address[] memory decoded = abi.decode(path, (address[]));
        require(decoded.length >= 2, "Treasury: Invalid path");
        start = decoded[0];
        end = decoded[decoded.length - 1];
    }

    function _encodeFeePath(address tokenA, address tokenB, uint24 fee) private pure returns (bytes memory data) {
        data = abi.encodePacked(tokenA, fee, tokenB);
    }

    function _readAddress(bytes memory data, uint256 start) private pure returns (address addr) {
        require(data.length >= start + 20, "Treasury: path read overflow");
        assembly {
            addr := shr(96, mload(add(add(data, 0x20), start)))
        }
    }

    // ------------ Hedera HTS: association ------------

    function associateTreasuryToToken(address token) external onlyRole(DAO_ROLE) {
        require(token != address(0), "Treasury: token=0");
        int64 rc = IHederaTokenService(HTS).associateToken(address(this), token);
        require(rc == 22 || rc == 0, "HTS associate failed"); // 22 = ALREADY_ASSOCIATED
        emit TreasuryAssociated(token);
    }

    function batchAssociateTreasuryToTokens(address[] calldata tokens) external onlyRole(DAO_ROLE) {
        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; i++) {
            address token = tokens[i];
            require(token != address(0), "Treasury: token=0");
            int64 rc = IHederaTokenService(HTS).associateToken(address(this), token);
            require(rc == 22 || rc == 0, "HTS associate failed");
            emit TreasuryAssociated(token);
        }
        emit TreasuryBatchAssociated(n);
    }

    // Accept native HBAR when Treasury is recipient in HBAR-out swaps
    receive() external payable {}
}

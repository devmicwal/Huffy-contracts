// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {PairWhitelist} from "./PairWhitelist.sol";
import {Treasury} from "./Treasury.sol";
import {ISwapAdapter} from "./interfaces/ISwapAdapter.sol";
import {ParameterStore} from "./ParameterStore.sol";
import {ITradeValidator} from "./interfaces/ITradeValidator.sol";

/**
 * @title Relay
 * @notice Validates and relays trade requests to Treasury with comprehensive DAO-controlled rules
 */
contract Relay is AccessControl, ReentrancyGuard {
    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE");
    bytes32 public constant TRADER_ROLE = keccak256("TRADER_ROLE");
    bytes32 public constant TIMELOCK_ROLE = keccak256("TIMELOCK_ROLE");

    // Contracts
    PairWhitelist public immutable PAIR_WHITELIST;
    Treasury public immutable TREASURY;
    ParameterStore public immutable PARAM_STORE;
    address public whbarToken;

    // State tracking
    uint256 public lastTradeTimestamp;
    ITradeValidator[] public VALIDATORS;

    // Trade types
    enum TradeType {
        SWAP,
        BUYBACK_AND_BURN
    }

    struct ValidationResult {
        bool isValid;
        uint256 maxTradeBps;
        uint256 maxSlippageBps;
        uint256 tradeCooldownSec;
        uint256 cooldownRemaining;
        uint256 treasuryBalance;
        uint256 impliedSlippage;
        uint256 maxAllowedAmount;
        bytes32[] reasonCodes;
    }

    // Events
    event TradeProposed(
        address indexed trader,
        TradeType indexed tradeType,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 timestamp
    );

    event TradeValidationFailed(
        address indexed trader,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 maxTradeBps,
        uint256 maxSlippageBps,
        uint256 cooldownRemaining,
        bytes32[] reasonCodes,
        uint256 timestamp
    );

    event TradeApproved(
        address indexed trader,
        TradeType indexed tradeType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 treasuryBalance,
        uint256 maxTradeBps,
        uint256 maxSlippageBps,
        uint256 timestamp
    );

    event TradeForwarded(
        address indexed trader,
        TradeType indexed tradeType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 timestamp
    );

    event TraderAuthorized(address indexed trader, uint256 timestamp);
    event TraderRevoked(address indexed trader, uint256 timestamp);
    event WhbarTokenUpdated(address indexed oldWhbar, address indexed newWhbar, uint256 timestamp);

    constructor(
        address _pairWhitelist,
        address payable _treasury,
        address _parameterStore,
        address _admin,
        address _timelock,
        address _whbarToken,
        address[] memory _initialTraders
    ) {
        require(_pairWhitelist != address(0), "Relay: Invalid whitelist");
        require(_treasury != address(0), "Relay: Invalid treasury");
        require(_parameterStore != address(0), "Relay: Invalid parameter store");
        require(_admin != address(0), "Relay: Invalid admin");
        require(_timelock != address(0), "Relay: Invalid timelock");
        require(_whbarToken != address(0), "Relay: Invalid WHBAR token");
        require(_initialTraders.length > 0, "Relay: No initial traders");

        PAIR_WHITELIST = PairWhitelist(_pairWhitelist);
        TREASURY = Treasury(_treasury);
        PARAM_STORE = ParameterStore(_parameterStore);
        whbarToken = _whbarToken;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(DAO_ROLE, _admin);
        _grantRole(TIMELOCK_ROLE, _timelock);

        for (uint256 i = 0; i < _initialTraders.length; i++) {
            require(_initialTraders[i] != address(0), "Relay: Invalid trader");
            _grantRole(TRADER_ROLE, _initialTraders[i]);
            emit TraderAuthorized(_initialTraders[i], block.timestamp);
        }
    }

    /**
     * @notice Submit a generic swap trade proposal (supports all swap kinds from Treasury)
     * @param kind Swap kind (see ISwapAdapter.SwapKind)
     * @param tokenIn Address of input token (address(0) for HBAR kinds)
     * @param tokenOut Address of output token
     * @param path Encoded swap path for the adapter
     * @param amountIn Amount of tokenIn (exact-in) or max-in (exact-out)
     * @param amountOut Amount expected (exact-out flows)
     * @param amountOutMin Minimum output (exact-in flows)
     * @param deadline Swap deadline timestamp
     * @return amountOutReceived Actual amount received
     */
    function proposeSwap(
        ISwapAdapter.SwapKind kind,
        address tokenIn,
        address tokenOut,
        bytes calldata path,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountOutMin,
        uint256 expectedAmountOut,
        uint256 deadline
    )
        external
        payable
        onlyRole(TRADER_ROLE)
        nonReentrant
        returns (uint256 amountOutReceived, bytes32[] memory reasonCodes)
    {
        emit TradeProposed(msg.sender, TradeType.SWAP, tokenIn, tokenOut, amountIn, amountOutMin, block.timestamp);
        require(path.length > 0, "Relay: Invalid path");

        ValidationResult memory vr = _validateTrade(tokenIn, tokenOut, amountIn, amountOutMin, expectedAmountOut);
        if (!vr.isValid) {
            emit TradeValidationFailed(
                msg.sender,
                tokenIn,
                tokenOut,
                amountIn,
                amountOutMin,
                vr.maxTradeBps,
                vr.maxSlippageBps,
                vr.cooldownRemaining,
                vr.reasonCodes,
                block.timestamp
            );
            return (0, vr.reasonCodes);
        }

        // Basic checks for HBAR flows (Treasury funds; msg.value must be zero)
        if (kind == ISwapAdapter.SwapKind.ExactHBARForTokens || kind == ISwapAdapter.SwapKind.HBARForExactTokens) {
            require(tokenIn == address(0) || tokenIn == whbarToken, "Relay: tokenIn must be HBAR/WHBAR");
            require(msg.value == 0, "Relay: msg.value must be zero");
            tokenIn = address(0);
        } else {
            require(msg.value == 0, "Relay: Unexpected value");
        }

        emit TradeApproved(
            msg.sender,
            TradeType.SWAP,
            tokenIn,
            tokenOut,
            amountIn,
            amountOutMin,
            tokenIn == address(0) ? address(TREASURY).balance : TREASURY.getBalance(tokenIn),
            vr.maxTradeBps,
            vr.maxSlippageBps,
            block.timestamp
        );
        lastTradeTimestamp = block.timestamp;

        amountOutReceived =
            TREASURY.executeSwap(kind, tokenIn, tokenOut, path, amountIn, amountOut, amountOutMin, deadline);

        emit TradeForwarded(msg.sender, TradeType.SWAP, tokenIn, tokenOut, amountIn, amountOutReceived, block.timestamp);
        return (amountOutReceived, new bytes32[](0));
    }

    /**
     * @notice Submit a buyback-and-burn trade proposal
     * @param tokenIn Address of input token
     * @param pathToQuote Path from tokenIn to QUOTE_TOKEN (empty if tokenIn == QUOTE_TOKEN)
     * @param amountIn Amount of tokenIn to swap for HTK
     * @param minQuoteOut Minimum QUOTE_TOKEN out when swapping tokenIn -> QUOTE_TOKEN
     * @param minAmountOut Minimum HTK to receive
     * @param maxHtkPriceD18 Maximum acceptable HTK price in 18d format (quote/htk)
     * @param deadline Swap deadline timestamp
     * @return burnedAmount Amount of HTK burned
     */
    function proposeBuybackAndBurn(
        address tokenIn,
        bytes calldata pathToQuote,
        bytes calldata pathQuoteToHtk,
        uint256 amountIn,
        uint256 minQuoteOut,
        uint256 minAmountOut,
        uint256 maxHtkPriceD18,
        uint256 deadline
    ) external onlyRole(TIMELOCK_ROLE) nonReentrant returns (uint256 burnedAmount, bytes32[] memory reasonCodes) {
        address htkToken = TREASURY.HTK_TOKEN();
        emit TradeProposed(
            msg.sender, TradeType.BUYBACK_AND_BURN, tokenIn, htkToken, amountIn, minAmountOut, block.timestamp
        );
        if (tokenIn != TREASURY.QUOTE_TOKEN()) {
            require(pathToQuote.length > 0, "Relay: Invalid path to quote");
        }
        require(pathQuoteToHtk.length > 0, "Relay: Invalid path quote to HTK");

        ValidationResult memory vr = _validateTrade(tokenIn, htkToken, amountIn, minAmountOut, minAmountOut);
        if (!vr.isValid) {
            emit TradeValidationFailed(
                msg.sender,
                tokenIn,
                htkToken,
                amountIn,
                minAmountOut,
                vr.maxTradeBps,
                vr.maxSlippageBps,
                vr.cooldownRemaining,
                vr.reasonCodes,
                block.timestamp
            );
            return (0, vr.reasonCodes);
        }
        emit TradeApproved(
            msg.sender,
            TradeType.BUYBACK_AND_BURN,
            tokenIn,
            htkToken,
            amountIn,
            minAmountOut,
            TREASURY.getBalance(tokenIn),
            vr.maxTradeBps,
            vr.maxSlippageBps,
            block.timestamp
        );
        lastTradeTimestamp = block.timestamp;
        burnedAmount = TREASURY.executeBuybackAndBurn(
            tokenIn, pathToQuote, pathQuoteToHtk, amountIn, minQuoteOut, minAmountOut, maxHtkPriceD18, deadline
        );
        emit TradeForwarded(
            msg.sender, TradeType.BUYBACK_AND_BURN, tokenIn, htkToken, amountIn, burnedAmount, block.timestamp
        );
        return (burnedAmount, new bytes32[](0));
    }

    function _validateTrade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 expectedAmountOut
    ) internal view returns (ValidationResult memory vr) {
        vr.maxTradeBps = PARAM_STORE.maxTradeBps();
        vr.maxSlippageBps = PARAM_STORE.maxSlippageBps();
        vr.tradeCooldownSec = PARAM_STORE.tradeCooldownSec();
        if (lastTradeTimestamp > 0) {
            uint256 elapsed = block.timestamp - lastTradeTimestamp;
            if (elapsed < vr.tradeCooldownSec) {
                vr.cooldownRemaining = vr.tradeCooldownSec - elapsed;
            }
        }
        bool pairWhitelisted = PAIR_WHITELIST.isPairWhitelisted(tokenIn, tokenOut);
        if (tokenIn == whbarToken) {
            vr.treasuryBalance = address(TREASURY).balance;
        } else {
            vr.treasuryBalance = TREASURY.getBalance(tokenIn);
        }
        vr.maxAllowedAmount = (vr.treasuryBalance * vr.maxTradeBps) / 10000;
        vr.impliedSlippage = _calculateImpliedSlippage(minAmountOut, expectedAmountOut);
        ITradeValidator.TradeContext memory ctx = ITradeValidator.TradeContext({
            maxTradeBps: vr.maxTradeBps,
            maxSlippageBps: vr.maxSlippageBps,
            tradeCooldownSec: vr.tradeCooldownSec,
            lastTradeTimestamp: lastTradeTimestamp,
            cooldownRemaining: vr.cooldownRemaining,
            treasuryBalance: vr.treasuryBalance,
            maxAllowedAmount: vr.maxAllowedAmount,
            impliedSlippage: vr.impliedSlippage,
            pairWhitelisted: pairWhitelisted
        });
        uint256 validatorsLen = VALIDATORS.length;
        bytes32[] memory tmp = new bytes32[](validatorsLen * 4);
        uint256 reasonCount = 0;
        for (uint256 i = 0; i < validatorsLen; i++) {
            (bool ok, bytes32 code) = VALIDATORS[i].validate(msg.sender, tokenIn, tokenOut, amountIn, minAmountOut, ctx);
            if (!ok) {
                tmp[reasonCount++] = code;
            }
        }
        bytes32[] memory reasons = new bytes32[](reasonCount);
        for (uint256 i = 0; i < reasonCount; i++) {
            reasons[i] = tmp[i];
        }
        vr.reasonCodes = reasons;
        vr.isValid = (reasonCount == 0);
        return vr;
    }

    /**
     * @notice Calculate implied slippage
     * @dev Compares expected output with minAmountOut
     * @param minAmountOut Minimum acceptable output amount (with slippage tolerance)
     * @param expectedAmountOut Expected output amount
     */
    function _calculateImpliedSlippage(uint256 minAmountOut, uint256 expectedAmountOut)
        internal
        pure
        returns (uint256 slippageBps)
    {
        if (expectedAmountOut == 0 || minAmountOut >= expectedAmountOut) {
            return 0;
        }
        uint256 slippageAmount = expectedAmountOut - minAmountOut;
        slippageBps = (slippageAmount * 10_000) / expectedAmountOut;
        return slippageBps;
    }

    /**
     * @notice Authorize a new trader
     * @param trader Address of trader to authorize
     */
    function authorizeTrader(address trader) external onlyRole(DAO_ROLE) {
        require(trader != address(0), "Relay: Invalid trader");
        _grantRole(TRADER_ROLE, trader);
        emit TraderAuthorized(trader, block.timestamp);
    }

    /**
     * @notice Revoke trader authorization
     * @param trader Address of trader to revoke
     */
    function revokeTrader(address trader) external onlyRole(DAO_ROLE) {
        _revokeRole(TRADER_ROLE, trader);
        emit TraderRevoked(trader, block.timestamp);
    }

    function setWhbarToken(address _whbarToken) external onlyRole(DAO_ROLE) {
        require(_whbarToken != address(0), "Relay: Invalid WHBAR token");
        address old = whbarToken;
        require(_whbarToken != old, "Relay: Same WHBAR token");
        whbarToken = _whbarToken;
        emit WhbarTokenUpdated(old, _whbarToken, block.timestamp);
    }

    /**
     * @notice Get current risk parameters snapshot
     */
    function getRiskParameters()
        external
        view
        returns (uint256 _maxTradeBps, uint256 _maxSlippageBps, uint256 _tradeCooldownSec, uint256 _lastTradeTimestamp)
    {
        return
            (
                PARAM_STORE.maxTradeBps(),
                PARAM_STORE.maxSlippageBps(),
                PARAM_STORE.tradeCooldownSec(),
                lastTradeTimestamp
            );
    }

    /**
     * @notice Get the maximum allowed trade amount for a given input token under current settings
     * @dev Computed as (Treasury balance of tokenIn) * maxTradeBps / 10000
     * @param tokenIn Address of input token
     * @return maxAllowedAmount Maximum amount allowed for a single trade
     */
    function getMaxAllowedTradeAmount(address tokenIn) external view returns (uint256 maxAllowedAmount) {
        uint256 treasuryBalance = TREASURY.getBalance(tokenIn);
        uint256 _maxTradeBps = PARAM_STORE.maxTradeBps();
        maxAllowedAmount = (treasuryBalance * _maxTradeBps) / 10000;
    }

    /**
     * @notice Calculate remaining cooldown time
     * @return remaining seconds until next trade allowed (0 if ready)
     */
    function getCooldownRemaining() external view returns (uint256) {
        if (lastTradeTimestamp == 0) return 0;
        uint256 tradeCooldownSec = PARAM_STORE.tradeCooldownSec();
        uint256 elapsed = block.timestamp - lastTradeTimestamp;
        if (elapsed >= tradeCooldownSec) return 0;
        return tradeCooldownSec - elapsed;
    }

    /**
     * @notice Add a validator by address (DAO only)
     * @param validator Address of the validator contract implementing ITradeValidator
     */
    function addValidator(address validator) external onlyRole(DAO_ROLE) {
        require(validator != address(0), "Relay: invalid validator");
        for (uint256 i = 0; i < VALIDATORS.length; i++) {
            if (address(VALIDATORS[i]) == validator) {
                revert("Relay: validator already added");
            }
        }
        VALIDATORS.push(ITradeValidator(validator));
    }

    /**
     * @notice Remove a validator by address (DAO only)
     * @param validator Address of the validator to remove
     */
    function removeValidator(address validator) external onlyRole(DAO_ROLE) {
        uint256 len = VALIDATORS.length;
        for (uint256 i = 0; i < len; i++) {
            if (address(VALIDATORS[i]) == validator) {
                VALIDATORS[i] = VALIDATORS[len - 1];
                VALIDATORS.pop();
                return;
            }
        }
        revert("Relay: validator not found");
    }

    function _extractPathEndpoints(bytes memory path) private pure returns (address start, address end) {
        require(path.length > 0, "Relay: Invalid path");

        // fee-style path: token(20) + [fee(3) + token(20)]*
        if (path.length >= 43 && (path.length - 20) % 23 == 0) {
            start = _readAddress(path, 0);
            uint256 tokenCount = 1 + (path.length - 20) / 23;
            uint256 lastOffset = 23 * (tokenCount - 1);
            end = _readAddress(path, lastOffset);
            return (start, end);
        }

        address[] memory decoded = abi.decode(path, (address[]));
        require(decoded.length >= 2, "Relay: Invalid path");
        start = decoded[0];
        end = decoded[decoded.length - 1];
    }

    function _readAddress(bytes memory data, uint256 start) private pure returns (address addr) {
        require(data.length >= start + 20, "Relay: path read overflow");
        assembly {
            addr := shr(96, mload(add(add(data, 0x20), start)))
        }
    }
}

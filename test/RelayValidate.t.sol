// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Relay} from "../src/Relay.sol";

import "forge-std/Test.sol";
import {BasicParamsValidator} from "../src/validators/BasicParamsValidator.sol";
import {ITradeValidator} from "../src/interfaces/ITradeValidator.sol";
import {MaxTradeSizeValidator} from "../src/validators/MaxTradeSizeValidator.sol";
import {PairWhitelistValidator} from "../src/validators/PairWhitelistValidator.sol";
import {SlippageValidator} from "../src/validators/SlippageValidator.sol";
import {Test} from "forge-std/Test.sol";
import {TreasuryBalanceValidator} from "../src/validators/TreasuryBalanceValidator.sol";
import {ISwapAdapter} from "../src/interfaces/ISwapAdapter.sol";

contract MockPairWhitelist {
    mapping(address => mapping(address => bool)) public pair;

    function setPair(address a, address b, bool v) external {
        pair[a][b] = v;
    }

    function isPairWhitelisted(address a, address b) external view returns (bool) {
        return pair[a][b];
    }
}

contract MockParameterStore {
    uint256 public maxTradeBps = 1000; // 10%
    uint256 public maxSlippageBps = 100; // 1%
    uint256 public tradeCooldownSec = 0;

    function set(uint256 a, uint256 b, uint256 c) external {
        maxTradeBps = a;
        maxSlippageBps = b;
        tradeCooldownSec = c;
    }
}

contract MockTreasury {
    address public immutable HTK_TOKEN = address(0x1234);
    address public immutable QUOTE_TOKEN = address(0x5678);
    address public burnSink = address(0xdead);
    mapping(address => uint256) public bal;

    function setBalance(address token, uint256 v) external {
        bal[token] = v;
    }

    function getBalance(address token) external view returns (uint256) {
        return bal[token];
    }

    function executeSwap(ISwapAdapter.SwapKind, address, address, bytes calldata, uint256, uint256, uint256, uint256)
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function executeBuybackAndBurn(
        address,
        bytes calldata,
        bytes calldata,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256
    ) external pure returns (uint256) {
        return 0;
    }
}

contract TestRelay is Relay {
    constructor(
        address _pairWhitelist,
        address payable _treasury,
        address _paramStore,
        address _admin,
        address _timelock,
        address _whbarToken,
        address[] memory _initialTraders
    ) Relay(_pairWhitelist, _treasury, _paramStore, _admin, _timelock, _whbarToken, _initialTraders) {}

    function exposeValidate(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 expectedAmountOut
    ) external view returns (ValidationResult memory) {
        return _validateTrade(tokenIn, tokenOut, amountIn, minAmountOut, expectedAmountOut);
    }

    function validatorsLength() external view returns (uint256) {
        return VALIDATORS.length;
    }
}

contract RelayValidateTest is Test {
    TestRelay relay;
    MockPairWhitelist pw;
    MockTreasury treasury;
    MockParameterStore params;

    address admin = address(this);
    address timelock = address(this);
    address trader = address(this);

    address tokenIn = address(0x1000);
    address tokenOut = address(0x2000);
    bytes path;

    function setUp() public {
        pw = new MockPairWhitelist();
        treasury = new MockTreasury();
        params = new MockParameterStore();
        path = abi.encodePacked(tokenIn, uint24(0), tokenOut);

        address[] memory traders = new address[](1);
        traders[0] = trader;
        address whbar = address(0x3000);
        relay = new TestRelay(address(pw), payable(address(treasury)), address(params), admin, timelock, whbar, traders);

        // Add validators
        relay.addValidator(address(new PairWhitelistValidator()));
        relay.addValidator(address(new MaxTradeSizeValidator()));
        relay.addValidator(address(new SlippageValidator()));
        relay.addValidator(address(new TreasuryBalanceValidator()));
        relay.addValidator(address(new BasicParamsValidator()));

        // Defaults
        pw.setPair(tokenIn, tokenOut, true);
        treasury.setBalance(tokenIn, 1_000_000);
        params.set(1000, 100, 0); // 10% max trade, 1% slippage, no cooldown
    }

    function test_validate_success() public view {
        uint256 amountIn = 10_000; // treasury balance 1,000,000 -> maxAllowed = 100,000
        uint256 expectedOut = amountIn * 100;
        uint256 minOut = expectedOut - (expectedOut * 50 / 10_000); // 50 bps slippage
        Relay.ValidationResult memory vr = relay.exposeValidate(tokenIn, tokenOut, amountIn, minOut, expectedOut);
        assertTrue(vr.isValid, "should be valid");
        assertEq(vr.reasonCodes.length, 0, "no reasons");
    }

    function test_pair_not_whitelisted() public {
        pw.setPair(tokenIn, tokenOut, false);
        Relay.ValidationResult memory vr = relay.exposeValidate(tokenIn, tokenOut, 100, 1, 1);
        assertFalse(vr.isValid);
        // first code equals PAIR_NOT_WHITELISTED
        assertEq(vr.reasonCodes[0], keccak256("PAIR_NOT_WHITELISTED"));
    }

    function test_exceeds_max_trade_size() public {
        params.set(1000, 100, 0); // 10%
        treasury.setBalance(tokenIn, 1_000); // maxAllowed = 100
        Relay.ValidationResult memory vr = relay.exposeValidate(tokenIn, tokenOut, 200, 1, 200);
        assertFalse(vr.isValid);
        assertContains(vr.reasonCodes, keccak256("EXCEEDS_MAX_TRADE_SIZE"));
    }

    function test_exceeds_max_slippage() public {
        params.set(1000, 100, 0); // 1% max
        uint256 amountIn = 100;
        uint256 expectedOut = amountIn * 100;
        uint256 minOut = expectedOut - (expectedOut * 200 / 10_000); // 200 bps -> 2%
        Relay.ValidationResult memory vr = relay.exposeValidate(tokenIn, tokenOut, amountIn, minOut, expectedOut);
        assertFalse(vr.isValid);
        assertContains(vr.reasonCodes, keccak256("EXCEEDS_MAX_SLIPPAGE"));
    }

    function test_insufficient_treasury_balance() public {
        treasury.setBalance(tokenIn, 50);
        Relay.ValidationResult memory vr = relay.exposeValidate(tokenIn, tokenOut, 100, 1, 100);
        assertFalse(vr.isValid);
        assertContains(vr.reasonCodes, keccak256("INSUFFICIENT_TREASURY_BALANCE"));
    }

    function test_invalid_parameters() public view {
        Relay.ValidationResult memory vr = relay.exposeValidate(address(0), tokenOut, 100, 0, 100);
        assertFalse(vr.isValid);
        assertContains(vr.reasonCodes, keccak256("INVALID_PARAMETERS"));
    }

    function test_removeValidator_byAddress() public {
        // add dummy validator
        DummyValidator dv = new DummyValidator();
        relay.addValidator(address(dv));
        uint256 lenBefore = relay.validatorsLength();

        relay.removeValidator(address(dv));
        uint256 lenAfter = relay.validatorsLength();
        assertEq(lenAfter, lenBefore - 1, "should remove one");

        vm.expectRevert(bytes("Relay: validator not found"));
        relay.removeValidator(address(dv));
    }

    function assertContains(bytes32[] memory arr, bytes32 val) internal pure {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == val) return;
        }
        revert("value not found");
    }
}

contract DummyValidator is ITradeValidator {
    function validate(address, address, address, uint256, uint256, TradeContext calldata)
        external
        pure
        returns (bool, bytes32)
    {
        return (false, keccak256("UNKNOWN_REASON"));
    }
}

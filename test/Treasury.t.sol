// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockSaucerswapRouter} from "../src/mocks/MockSaucerswapRouter.sol";
import {MockRelay} from "../src/mocks/MockRelay.sol";
import {MockSwapAdapter} from "../src/mocks/MockSwapAdapter.sol";
import {ISwapAdapter} from "../src/interfaces/ISwapAdapter.sol";
import {SafeERC20, IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract TreasuryTest is Test {
    using SafeERC20 for IERC20;

    Treasury public treasury;
    MockRelay public mockRelay;
    MockERC20 public htkToken;
    MockERC20 public usdcToken;
    MockERC20 public usdtToken;
    MockSaucerswapRouter public saucerswapRouter;
    MockSwapAdapter public swapAdapter;
    address public whbarToken;
    uint24 public constant QUOTE_FEE = 3000;

    address public owner;
    address public dao;
    address public user1;
    address public user2;
    address public unauthorized;

    uint256 constant INITIAL_SUPPLY = 1_000_000e6;
    // Exchange rates in MockSaucerswapRouter are 1e18-scaled (fixed-point, 18 decimals),
    // independent of token decimals. With 6→6 tokens, amountOut = (amountIn * EXCHANGE_RATE_1E18) / 1e18.
    // Example: 1 USDC = 2 HTK => EXCHANGE_RATE_1E18 = 2e18.
    uint256 constant EXCHANGE_RATE_1E18 = 2e18; // 1 USDC = 2 HTK (1e18-scaled)

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

    function _encodePath(address tokenIn, address tokenOut) internal pure returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        return abi.encode(path);
    }

    function setUp() public {
        owner = address(this);
        dao = makeAddr("dao");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        unauthorized = makeAddr("unauthorized");
        whbarToken = address(0x1234);

        // Deploy mock tokens
        htkToken = new MockERC20("HTK Token", "HTK", 6);
        usdcToken = new MockERC20("USDC Token", "USDC", 6);
        usdtToken = new MockERC20("USDT Token", "USDT", 6);

        // Deploy mock Saucerswap router + adapter
        saucerswapRouter = new MockSaucerswapRouter();
        swapAdapter = new MockSwapAdapter(address(saucerswapRouter));

        // Deploy Treasury
        treasury = new Treasury(
            address(htkToken),
            address(usdcToken),
            QUOTE_FEE,
            address(swapAdapter),
            dao,
            owner,
            address(0xdead),
            whbarToken
        );

        // Mint tokens
        htkToken.mint(owner, INITIAL_SUPPLY);
        htkToken.mint(address(saucerswapRouter), INITIAL_SUPPLY);
        usdcToken.mint(user1, 100_000e6);
        usdcToken.mint(address(treasury), 10_000e6);
        usdtToken.mint(address(treasury), 10_000e6);

        // Setup exchange rate
        saucerswapRouter.setExchangeRate(address(usdcToken), address(htkToken), EXCHANGE_RATE_1E18);

        // Deploy MockRelay
        mockRelay = new MockRelay(payable(address(treasury)));

        // Update relay in treasury
        vm.prank(dao);
        treasury.updateRelay(owner, address(mockRelay));
    }

    /* ============ Deployment Tests ============ */

    function test_Deployment() public view {
        assertEq(treasury.HTK_TOKEN(), address(htkToken));
        assertEq(address(treasury.adapter()), address(swapAdapter));
        assertEq(treasury.QUOTE_TOKEN(), address(usdcToken));
        assertEq(treasury.quoteToHtkFee(), QUOTE_FEE);

        bytes32 daoRole = treasury.DAO_ROLE();
        assertTrue(treasury.hasRole(daoRole, dao));

        bytes32 relayRole = treasury.RELAY_ROLE();
        assertTrue(treasury.hasRole(relayRole, address(mockRelay)));
    }

    function test_RevertWhen_DeployWithZeroHTKToken() public {
        vm.expectRevert(bytes("Treasury: Invalid HTK token"));
        new Treasury(
            address(0), address(usdcToken), QUOTE_FEE, address(swapAdapter), dao, owner, address(0xdead), whbarToken
        );
    }

    function test_RevertWhen_DeployWithZeroAdapter() public {
        vm.expectRevert(bytes("Treasury: Invalid adapter"));
        new Treasury(
            address(htkToken), address(usdcToken), QUOTE_FEE, address(0), dao, owner, address(0xdead), whbarToken
        );
    }

    function test_RevertWhen_DeployWithZeroAdmin() public {
        vm.expectRevert(bytes("Treasury: Invalid admin"));
        new Treasury(
            address(htkToken),
            address(usdcToken),
            QUOTE_FEE,
            address(swapAdapter),
            address(0),
            owner,
            address(0xdead),
            whbarToken
        );
    }

    function test_RevertWhen_DeployWithZeroRelay() public {
        vm.expectRevert(bytes("Treasury: Invalid relay"));
        new Treasury(
            address(htkToken),
            address(usdcToken),
            QUOTE_FEE,
            address(swapAdapter),
            dao,
            address(0),
            address(0xdead),
            whbarToken
        );
    }

    /* ============ Deposit Tests ============ */

    function test_Deposit() public {
        uint256 depositAmount = 1000e6;

        vm.startPrank(user1);
        usdcToken.approve(address(treasury), depositAmount);

        vm.expectEmit(true, true, false, true);
        emit Deposited(address(usdcToken), user1, depositAmount, block.timestamp);

        treasury.deposit(address(usdcToken), depositAmount);
        vm.stopPrank();

        assertEq(treasury.getBalance(address(usdcToken)), 11_000e6);
    }

    function testFuzz_Deposit(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 100_000e6);

        vm.startPrank(user1);
        usdcToken.approve(address(treasury), amount);
        treasury.deposit(address(usdcToken), amount);
        vm.stopPrank();

        assertEq(treasury.getBalance(address(usdcToken)), 10_000e6 + amount);
    }

    function test_RevertWhen_DepositZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(bytes("Treasury: Zero amount"));
        treasury.deposit(address(usdcToken), 0);
    }

    function test_RevertWhen_DepositInvalidToken() public {
        vm.prank(user1);
        vm.expectRevert(bytes("Treasury: Invalid token"));
        treasury.deposit(address(0), 1000);
    }

    function test_MultipleDeposits() public {
        uint256 depositAmount1 = 1000e6;
        uint256 depositAmount2 = 500e6;

        vm.startPrank(user1);
        usdcToken.approve(address(treasury), depositAmount1);
        treasury.deposit(address(usdcToken), depositAmount1);

        usdcToken.approve(address(treasury), depositAmount2);
        treasury.deposit(address(usdcToken), depositAmount2);
        vm.stopPrank();

        assertEq(treasury.getBalance(address(usdcToken)), 11_500e6);
    }

    /* ============ Withdraw Tests ============ */

    function test_Withdraw() public {
        uint256 withdrawAmount = 1000e6;
        uint256 initialBalance = usdcToken.balanceOf(user2);

        vm.prank(dao);
        vm.expectEmit(true, true, false, true);
        emit Withdrawn(address(usdcToken), user2, withdrawAmount, dao, block.timestamp);

        treasury.withdraw(address(usdcToken), user2, withdrawAmount);

        assertEq(usdcToken.balanceOf(user2), initialBalance + withdrawAmount);
    }

    function testFuzz_Withdraw(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 10_000e6);

        vm.prank(dao);
        treasury.withdraw(address(usdcToken), user2, amount);

        assertEq(treasury.getBalance(address(usdcToken)), 10_000e6 - amount);
    }

    function test_RevertWhen_WithdrawInsufficientBalance() public {
        vm.prank(dao);
        vm.expectRevert(bytes("Treasury: Insufficient balance"));
        treasury.withdraw(address(usdcToken), user2, 20_000e6);
    }

    function test_RevertWhen_WithdrawZeroAmount() public {
        vm.prank(dao);
        vm.expectRevert(bytes("Treasury: Zero amount"));
        treasury.withdraw(address(usdcToken), user2, 0);
    }

    function test_RevertWhen_WithdrawInvalidToken() public {
        vm.prank(dao);
        vm.expectRevert(bytes("Treasury: Invalid token"));
        treasury.withdraw(address(0), user2, 1000);
    }

    function test_RevertWhen_WithdrawInvalidRecipient() public {
        vm.prank(dao);
        vm.expectRevert(bytes("Treasury: Invalid recipient"));
        treasury.withdraw(address(usdcToken), address(0), 1000);
    }

    /* ============ Buyback and Burn Tests ============ */

    function test_BuybackAndBurn() public {
        uint256 buybackAmount = 1000e6;
        uint256 expectedHtk = 2000e6; // 1000 USDC * 2 = 2000 HTK
        uint256 deadline = block.timestamp + 3600;

        vm.expectEmit(true, false, false, true);
        emit BuybackExecuted(address(usdcToken), buybackAmount, expectedHtk, address(mockRelay), block.timestamp);

        vm.expectEmit(false, false, false, true);
        emit Burned(expectedHtk, address(mockRelay), block.timestamp);

        mockRelay.executeBuybackAndBurn(
            address(usdcToken),
            bytes(""),
            _encodePath(address(usdcToken), address(htkToken)),
            buybackAmount,
            0,
            expectedHtk,
            type(uint256).max,
            deadline
        );

        // Check HTK was burned (sent to burn sink)
        assertEq(htkToken.balanceOf(address(0xdead)), expectedHtk);
    }

    function testFuzz_BuybackAndBurn(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 10_000e6);

        // amount is in smallest units of USDC (6 decimals). With matching decimals (6->6),
        // router computes amountOut = (amountIn * EXCHANGE_RATE_1E18) / 1e18.
        uint256 expectedHtk = (amount * EXCHANGE_RATE_1E18) / 1e18;
        uint256 deadline = block.timestamp + 3600;

        mockRelay.executeBuybackAndBurn(
            address(usdcToken),
            bytes(""),
            _encodePath(address(usdcToken), address(htkToken)),
            amount,
            0,
            expectedHtk,
            type(uint256).max,
            deadline
        );

        assertEq(htkToken.balanceOf(address(0xdead)), expectedHtk);
    }

    function test_RevertWhen_BuybackHTKForHTK() public {
        uint256 buybackAmount = 1000e6;
        uint256 deadline = block.timestamp + 3600;

        bytes memory path = _encodePath(address(htkToken), address(htkToken));
        vm.expectRevert(bytes("Treasury: Cannot swap HTK for HTK"));
        mockRelay.executeBuybackAndBurn(
            address(htkToken),
            path,
            _encodePath(address(usdcToken), address(htkToken)),
            buybackAmount,
            0,
            0,
            type(uint256).max,
            deadline
        );
    }

    function test_RevertWhen_BuybackWithEmptyPath() public {
        uint256 buybackAmount = 1000e6;
        uint256 deadline = block.timestamp + 3600;
        vm.expectRevert(bytes("Treasury: Path required"));
        mockRelay.executeBuybackAndBurn(
            address(usdtToken),
            bytes(""),
            _encodePath(address(usdcToken), address(htkToken)),
            buybackAmount,
            0,
            1,
            type(uint256).max,
            deadline
        );
    }

    function test_RevertWhen_BuybackExpiredDeadline() public {
        uint256 buybackAmount = 1000e6;
        uint256 deadline = block.timestamp - 1;

        vm.expectRevert(bytes("Treasury: Expired deadline"));
        mockRelay.executeBuybackAndBurn(
            address(usdcToken),
            bytes(""),
            _encodePath(address(usdcToken), address(htkToken)),
            buybackAmount,
            0,
            1,
            type(uint256).max,
            deadline
        );
    }

    function test_RevertWhen_BuybackInsufficientBalance() public {
        uint256 buybackAmount = 20_000e6;
        uint256 deadline = block.timestamp + 3600;

        vm.expectRevert(bytes("Treasury: Insufficient balance"));
        mockRelay.executeBuybackAndBurn(
            address(usdcToken),
            bytes(""),
            _encodePath(address(usdcToken), address(htkToken)),
            buybackAmount,
            0,
            1,
            type(uint256).max,
            deadline
        );
    }

    /* ============ Access Control Tests ============ */

    function test_UpdateRelay() public {
        address newRelay = makeAddr("newRelay");

        vm.prank(dao);
        vm.expectEmit(true, true, false, true);
        emit RelayUpdated(address(mockRelay), newRelay, block.timestamp);

        treasury.updateRelay(address(mockRelay), newRelay);

        bytes32 relayRole = treasury.RELAY_ROLE();
        assertTrue(treasury.hasRole(relayRole, newRelay));
        assertFalse(treasury.hasRole(relayRole, address(mockRelay)));
    }

    function test_RevertWhen_UpdateRelaySameAddress() public {
        vm.prank(dao);
        vm.expectRevert(bytes("Treasury: Same relay"));
        treasury.updateRelay(address(mockRelay), address(mockRelay));
    }

    function test_RevertWhen_UpdateRelayZeroAddress() public {
        vm.prank(dao);
        vm.expectRevert(bytes("Treasury: Invalid relay"));
        treasury.updateRelay(address(mockRelay), address(0));
    }

    function test_SetAdapter() public {
        MockSwapAdapter newAdapter = new MockSwapAdapter(address(saucerswapRouter));

        vm.prank(dao);
        vm.expectEmit(true, true, false, true);
        emit AdapterUpdated(address(swapAdapter), address(newAdapter), block.timestamp);

        treasury.setAdapter(address(newAdapter));
        assertEq(address(treasury.adapter()), address(newAdapter));
    }

    function test_RevertWhen_SetAdapterSame() public {
        vm.prank(dao);
        vm.expectRevert(bytes("Treasury: Same adapter"));
        treasury.setAdapter(address(swapAdapter));
    }

    function test_RevertWhen_SetAdapterZero() public {
        vm.prank(dao);
        vm.expectRevert(bytes("Treasury: Invalid adapter"));
        treasury.setAdapter(address(0));
    }

    function test_RevertWhen_SetAdapterNotDao() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        treasury.setAdapter(address(swapAdapter));
    }

    /* ============ Integration Tests ============ */

    function test_FullFlow_DepositBuybackBurn() public {
        // 1. User deposits USDC
        uint256 depositAmount = 5000e6;
        vm.startPrank(user1);
        usdcToken.approve(address(treasury), depositAmount);
        treasury.deposit(address(usdcToken), depositAmount);
        vm.stopPrank();

        // 2. Relay executes buyback and burn
        uint256 buybackAmount = 3000e6;
        uint256 expectedHtk = 6000e6;
        uint256 deadline = block.timestamp + 3600;

        mockRelay.executeBuybackAndBurn(
            address(usdcToken),
            bytes(""),
            _encodePath(address(usdcToken), address(htkToken)),
            buybackAmount,
            0,
            expectedHtk,
            type(uint256).max,
            deadline
        );

        // 3. Verify final state
        uint256 remainingUsdc = 12_000e6; // 10000 + 5000 - 3000
        assertEq(treasury.getBalance(address(usdcToken)), remainingUsdc);
        assertEq(htkToken.balanceOf(address(0xdead)), expectedHtk);
    }

    function test_MultipleBuybackOperations() public {
        uint256 buybackAmount1 = 1000e6;
        uint256 buybackAmount2 = 2000e6;
        uint256 deadline = block.timestamp + 3600;

        mockRelay.executeBuybackAndBurn(
            address(usdcToken),
            bytes(""),
            _encodePath(address(usdcToken), address(htkToken)),
            buybackAmount1,
            0,
            buybackAmount1 * 2,
            type(uint256).max,
            deadline
        );

        mockRelay.executeBuybackAndBurn(
            address(usdcToken),
            bytes(""),
            _encodePath(address(usdcToken), address(htkToken)),
            buybackAmount2,
            0,
            buybackAmount2 * 2,
            type(uint256).max,
            deadline
        );

        uint256 totalBurned = 6000e6; // (1000 + 2000) * 2
        assertEq(htkToken.balanceOf(address(0xdead)), totalBurned);
    }

    /* ============ View Function Tests ============ */

    function test_GetBalance() public view {
        uint256 balance = treasury.getBalance(address(usdcToken));
        assertEq(balance, 10_000e6);
    }

    function test_GetBalanceZero() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        uint256 balance = treasury.getBalance(address(newToken));
        assertEq(balance, 0);
    }

    /* ============ Swap Tests ============ */

    function test_Swap_USDCToHTK() public {
        uint256 amountIn = 1000e6;
        uint256 expectedOut = 2000e6; // 1000 USDC * 2 = 2000 HTK
        uint256 deadline = block.timestamp + 3600;

        vm.expectEmit(true, true, true, true);
        emit SwapExecuted(
            address(usdcToken), address(htkToken), amountIn, expectedOut, address(mockRelay), block.timestamp
        );

        uint256 htkBefore = htkToken.balanceOf(address(treasury));
        bytes memory path = _encodePath(address(usdcToken), address(htkToken));
        uint256 ret = mockRelay.executeSwap(
            ISwapAdapter.SwapKind.ExactTokensForTokens,
            address(usdcToken),
            address(htkToken),
            path,
            amountIn,
            0,
            expectedOut,
            deadline
        );
        uint256 htkAfter = htkToken.balanceOf(address(treasury));

        assertEq(ret, expectedOut);
        assertEq(htkAfter - htkBefore, expectedOut);
        assertEq(htkToken.balanceOf(address(0xdead)), 0);
    }

    function testFuzz_Swap_USDCToHTK(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 10_000e6);
        // With 6→6 decimals and EXCHANGE_RATE_1E18 scaled by 1e18, router computes: amountOut = (amountIn * EXCHANGE_RATE_1E18) / 1e18
        uint256 expectedOut = (amount * EXCHANGE_RATE_1E18) / 1e18;
        uint256 deadline = block.timestamp + 3600;

        uint256 outBefore = htkToken.balanceOf(address(treasury));
        bytes memory path = _encodePath(address(usdcToken), address(htkToken));
        uint256 ret = mockRelay.executeSwap(
            ISwapAdapter.SwapKind.ExactTokensForTokens,
            address(usdcToken),
            address(htkToken),
            path,
            amount,
            0,
            expectedOut,
            deadline
        );
        uint256 outAfter = htkToken.balanceOf(address(treasury));

        assertEq(ret, expectedOut);
        assertEq(outAfter - outBefore, expectedOut);
        assertEq(htkToken.balanceOf(address(0xdead)), 0);
    }

    function test_RevertWhen_SwapSameToken() public {
        uint256 amountIn = 100e6;
        uint256 deadline = block.timestamp + 3600;
        vm.expectRevert(bytes("Treasury: Same token"));
        bytes memory invalidPath = _encodePath(address(usdcToken), address(usdcToken));
        mockRelay.executeSwap(
            ISwapAdapter.SwapKind.ExactTokensForTokens,
            address(usdcToken),
            address(usdcToken),
            invalidPath,
            amountIn,
            0,
            0,
            deadline
        );
    }

    function test_RevertWhen_SwapExpiredDeadline() public {
        uint256 amountIn = 100e6;
        uint256 deadline = block.timestamp - 1;
        vm.expectRevert(bytes("Treasury: Expired deadline"));
        bytes memory path = _encodePath(address(usdcToken), address(htkToken));
        mockRelay.executeSwap(
            ISwapAdapter.SwapKind.ExactTokensForTokens,
            address(usdcToken),
            address(htkToken),
            path,
            amountIn,
            0,
            0,
            deadline
        );
    }

    function test_RevertWhen_SwapInsufficientBalance() public {
        uint256 amountIn = 20_000e6;
        uint256 minOut = 1;
        uint256 deadline = block.timestamp + 3600;
        vm.expectRevert(bytes("Treasury: Insufficient balance"));
        bytes memory path = _encodePath(address(usdcToken), address(htkToken));
        mockRelay.executeSwap(
            ISwapAdapter.SwapKind.ExactTokensForTokens,
            address(usdcToken),
            address(htkToken),
            path,
            amountIn,
            0,
            minOut,
            deadline
        );
    }

    function test_RevertWhen_SwapInvalidToken() public {
        uint256 amountIn = 1;
        uint256 deadline = block.timestamp + 3600;
        vm.expectRevert(bytes("Treasury: Invalid tokenIn"));
        bytes memory path = _encodePath(address(usdcToken), address(htkToken));
        mockRelay.executeSwap(
            ISwapAdapter.SwapKind.ExactTokensForTokens, address(0), address(htkToken), path, amountIn, 0, 0, deadline
        );
    }

    /* ============ Different Decimals Swap Tests ============ */

    function test_Swap_18To6_Decimals() public {
        // Create 18-decimal token (e.g., WETH)
        MockERC20 weth = new MockERC20("Wrapped ETH", "WETH", 18);

        // Fund Treasury with WETH18 and Router with HTK6
        uint256 wethTreasuryAmount = 10_000e18;
        weth.mint(address(treasury), wethTreasuryAmount);
        // htkToken already funded to router in setUp

        // Set exchange rate: 1 WETH = 2 HTK (1e18-scaled)
        saucerswapRouter.setExchangeRate(address(weth), address(htkToken), EXCHANGE_RATE_1E18);

        uint256 amountIn = 1e18; // 1 WETH
        // Compute expected out using min-dec normalization
        // min(decimals) = 6; adjustedIn = amountIn / 1e12; amountOutUnits = adjustedIn * rate / 1e18; amountOut = amountOutUnits
        uint256 expectedOut = (amountIn * EXCHANGE_RATE_1E18) / ((10 ** (18 - 6)) * 1e18);
        uint256 deadline = block.timestamp + 3600;

        uint256 outBefore = htkToken.balanceOf(address(treasury));
        bytes memory path = _encodePath(address(weth), address(htkToken));
        uint256 ret = mockRelay.executeSwap(
            ISwapAdapter.SwapKind.ExactTokensForTokens,
            address(weth),
            address(htkToken),
            path,
            amountIn,
            0,
            expectedOut,
            deadline
        );
        uint256 outAfter = htkToken.balanceOf(address(treasury));

        assertEq(ret, expectedOut);
        assertEq(outAfter - outBefore, expectedOut);
    }

    function test_Swap_6To18_Decimals() public {
        // Create 18-decimal token (e.g., WETH)
        MockERC20 weth = new MockERC20("Wrapped ETH", "WETH", 18);

        // Fund Router with WETH18 and Treasury has USDC6 already
        uint256 wethRouterAmount = 1_000_000e18;
        weth.mint(address(saucerswapRouter), wethRouterAmount);

        // Set exchange rate: 1 USDC = 2 WETH (1e18-scaled)
        saucerswapRouter.setExchangeRate(address(usdcToken), address(weth), EXCHANGE_RATE_1E18);

        uint256 amountIn = 1e6; // 1 USDC
        // min(decimals) = 6; adjustedIn = amountIn; amountOutUnits = adjustedIn * rate / 1e18; amountOut = amountOutUnits * 1e12
        uint256 expectedOut = ((amountIn) * EXCHANGE_RATE_1E18 * (10 ** (18 - 6))) / 1e18;
        uint256 deadline = block.timestamp + 3600;

        uint256 outBefore = weth.balanceOf(address(treasury));
        bytes memory path = _encodePath(address(usdcToken), address(weth));
        uint256 ret = mockRelay.executeSwap(
            ISwapAdapter.SwapKind.ExactTokensForTokens,
            address(usdcToken),
            address(weth),
            path,
            amountIn,
            0,
            expectedOut,
            deadline
        );
        uint256 outAfter = weth.balanceOf(address(treasury));

        assertEq(ret, expectedOut);
        assertEq(outAfter - outBefore, expectedOut);
    }
}

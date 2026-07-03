// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GestureMarket} from "../src/GestureMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";
import {MarketTestBase} from "./utils/MarketTestBase.sol";
import {MockGame, ReenteringCst, FalseReturningCst, IReentryHook} from "./utils/Mocks.sol";

/// @notice Attacker that reenters `claim()` while the market is paying it out.
contract ClaimReenterer is IReentryHook {
    GestureMarket public immutable market;
    uint256 public constant NOT_ATTEMPTED = type(uint256).max;
    uint256 public constant REVERTED = type(uint256).max - 1;
    uint256 public reentryResult = NOT_ATTEMPTED;
    bool internal reentered;

    constructor(GestureMarket market_) {
        market = market_;
    }

    function claimOnce() external returns (uint256) {
        return market.claim();
    }

    function onCstReceived() external {
        if (reentered) return;
        reentered = true;
        try market.claim() returns (uint256 second) {
            reentryResult = second;
        } catch {
            reentryResult = REVERTED;
        }
    }
}

/// @notice Attacker that reenters `redeemSets()` while receiving the redemption.
contract RedeemReenterer is IReentryHook {
    GestureMarket public immutable market;
    uint256 public immutable amount;
    bool public reentryReverted;
    bool internal reentered;

    constructor(GestureMarket market_, uint256 amount_) {
        market = market_;
        amount = amount_;
    }

    function redeemOnce() external {
        market.redeemSets(amount);
    }

    function onCstReceived() external {
        if (reentered) return;
        reentered = true;
        // Try to redeem the same (already burned) sets again mid-transfer.
        try market.redeemSets(amount) {
            reentryReverted = false;
        } catch {
            reentryReverted = true;
        }
    }
}

/// @notice Adversarial and hostile-environment tests: reentrancy, misbehaving
/// tokens, direct donations, degenerate parameters, and lifecycle abuse.
contract GestureMarketHardeningTest is MarketTestBase {
    // ------------------------------------------------------------------
    // Reentrancy
    // ------------------------------------------------------------------

    /// @dev Builds a market whose CST notifies recipients mid-transfer,
    /// simulating an ERC-777-style callback token.
    function _deployReenteringMarket() internal returns (GestureMarket m, ReenteringCst evilCst) {
        evilCst = new ReenteringCst();
        MockGame evilGame = new MockGame(address(evilCst));
        evilGame.setRoundNum(ROUND);

        evilCst.mint(creator, LIQ);
        address predicted = vm.computeCreateAddress(creator, vm.getNonce(creator));
        vm.prank(creator);
        evilCst.approve(predicted, type(uint256).max);
        vm.prank(creator);
        m = new GestureMarket(ICosmicSignatureGame(address(evilGame)), MIN, MAX, FEE_BPS, LIQ);

        // Swap the base fixture's game for the evil one so helpers keep working.
        game = evilGame;
    }

    function test_claimIsReentrancySafe() public {
        (GestureMarket m, ReenteringCst evilCst) = _deployReenteringMarket();

        ClaimReenterer attacker = new ClaimReenterer(m);
        evilCst.mint(address(attacker), 1_000e18);
        vm.prank(address(attacker));
        evilCst.approve(address(m), type(uint256).max);
        vm.prank(address(attacker));
        m.betHigher(1_000e18, 0);
        uint256 entitled = m.higherBalance(address(attacker));

        _endRoundWith(1_000); // f = 0.8
        m.resolve();
        uint256 expectedPayout = entitled * 0.8e18 / 1e18;

        evilCst.setHook(address(attacker));
        uint256 firstPayout = attacker.claimOnce();

        assertEq(firstPayout, expectedPayout, "legitimate claim must pay in full");
        assertEq(attacker.reentryResult(), 0, "reentrant claim must pay exactly zero");
        assertEq(evilCst.balanceOf(address(attacker)), expectedPayout, "attacker extracted extra CST");
        assertEq(m.higherBalance(address(attacker)), 0);
    }

    function test_redeemSetsIsReentrancySafe() public {
        (GestureMarket m, ReenteringCst evilCst) = _deployReenteringMarket();

        RedeemReenterer attacker = new RedeemReenterer(m, 500e18);
        evilCst.mint(address(attacker), 500e18);
        vm.prank(address(attacker));
        evilCst.approve(address(m), type(uint256).max);
        vm.prank(address(attacker));
        m.mintSets(500e18);

        evilCst.setHook(address(attacker));
        attacker.redeemOnce();

        assertTrue(attacker.reentryReverted(), "double redeem must revert (balances zeroed first)");
        assertEq(evilCst.balanceOf(address(attacker)), 500e18, "attacker must get exactly one redemption");
        assertEq(m.higherBalance(address(attacker)), 0);
        assertEq(m.lowerBalance(address(attacker)), 0);
    }

    // ------------------------------------------------------------------
    // Misbehaving tokens
    // ------------------------------------------------------------------

    /// A token returning false (instead of reverting) must surface as
    /// TransferFailed everywhere, never as silent success.
    function test_falseReturningTokenIsRejected() public {
        FalseReturningCst badCst = new FalseReturningCst();
        MockGame badGame = new MockGame(address(badCst));
        badGame.setRoundNum(ROUND);
        badCst.mint(creator, LIQ);

        // Failure during construction (seeding liquidity).
        vm.prank(creator);
        badCst.approve(vm.computeCreateAddress(creator, vm.getNonce(creator)), type(uint256).max);
        badCst.setFailTransfers(true);
        vm.expectRevert(GestureMarket.TransferFailed.selector);
        vm.prank(creator);
        new GestureMarket(ICosmicSignatureGame(address(badGame)), MIN, MAX, FEE_BPS, LIQ);

        // Deploy successfully, then fail on a bet and on a redemption. Note the
        // reverted creation above still consumed a nonce, so re-predict and
        // re-approve the next deployment address.
        badCst.setFailTransfers(false);
        vm.prank(creator);
        badCst.approve(vm.computeCreateAddress(creator, vm.getNonce(creator)), type(uint256).max);
        vm.prank(creator);
        GestureMarket m = new GestureMarket(ICosmicSignatureGame(address(badGame)), MIN, MAX, FEE_BPS, LIQ);

        badCst.mint(alice, 100e18);
        vm.startPrank(alice);
        badCst.approve(address(m), type(uint256).max);
        m.mintSets(50e18);

        badCst.setFailTransfers(true);
        vm.expectRevert(GestureMarket.TransferFailed.selector);
        m.betHigher(10e18, 0);
        vm.expectRevert(GestureMarket.TransferFailed.selector);
        m.redeemSets(50e18);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Unsolicited CST donations
    // ------------------------------------------------------------------

    /// Direct CST transfers into the market must not change anyone's payout —
    /// claims follow the resolved formula exactly, and the donation stays put.
    function testFuzz_directDonationDoesNotAffectPayouts(uint256 donation, uint256 finalCount) public {
        donation = bound(donation, 1, 1e24);

        vm.prank(alice);
        market.betHigher(2_000e18, 0);
        vm.prank(bob);
        market.betLower(1_000e18, 0);

        cst.mint(address(market), donation); // hostile/accidental donation

        _endRoundWith(bound(finalCount, 0, 5_000));
        market.resolve();
        uint256 f = market.payoutPerHigher();

        uint256 aliceExpected = market.higherBalance(alice) * f / 1e18;
        uint256 bobExpected = market.lowerBalance(bob) * (1e18 - f) / 1e18;

        vm.prank(alice);
        assertEq(market.claim(), aliceExpected, "donation changed alice's payout");
        vm.prank(bob);
        assertEq(market.claim(), bobExpected, "donation changed bob's payout");
        vm.prank(creator);
        market.claim();

        assertGe(cst.balanceOf(address(market)), donation, "someone extracted the donation");
    }

    // ------------------------------------------------------------------
    // Degenerate parameters and inputs
    // ------------------------------------------------------------------

    function test_zeroAmountOperationsAreHarmlessNoops() public {
        uint256 reserveHigherBefore = market.reserveHigher();
        uint256 reserveLowerBefore = market.reserveLower();

        vm.startPrank(alice);
        assertEq(market.betHigher(0, 0), 0);
        assertEq(market.betLower(0, 0), 0);
        market.mintSets(0);
        market.redeemSets(0);
        vm.stopPrank();

        assertEq(market.reserveHigher(), reserveHigherBefore);
        assertEq(market.reserveLower(), reserveLowerBefore);
        assertEq(market.feesAccrued(), 0);
        assertEq(market.quoteBetHigher(0), 0);
        assertEq(market.quoteBetLower(0), 0);
    }

    /// The tightest possible range still resolves correctly on both sides.
    function test_binaryRangeMarket() public {
        GestureMarket m = _deployMarket(700, 701, FEE_BPS, LIQ);
        vm.startPrank(alice);
        cst.approve(address(m), type(uint256).max);
        m.betHigher(100e18, 0);
        vm.stopPrank();

        uint256 snap = vm.snapshotState();
        _endRoundWith(700);
        m.resolve();
        assertEq(m.payoutPerHigher(), 0);

        vm.revertToState(snap);
        _endRoundWith(701);
        m.resolve();
        assertEq(m.payoutPerHigher(), 1e18);
    }

    /// The widest allowed range with the smallest possible liquidity must not
    /// revert anywhere in the lifecycle — even for a completely unbounded
    /// final count reported by the game.
    function testFuzz_widestRangeTinyLiquiditySurvives(uint256 betAmount, uint256 finalCount) public {
        betAmount = bound(betAmount, 1, 1_000_000e18);
        GestureMarket m = _deployMarket(0, 1e12, FEE_BPS, 1);

        vm.startPrank(alice);
        cst.approve(address(m), type(uint256).max);
        m.betHigher(betAmount, 0);
        vm.stopPrank();

        assertLe(m.predictedCount(), 1e12);

        game.setNumBids(ROUND, finalCount); // deliberately unbounded
        game.setRoundNum(ROUND + 1);
        m.resolve();
        assertLe(m.payoutPerHigher(), 1e18, "payout fraction above 100%");

        uint256 h = m.higherBalance(alice);
        vm.prank(alice);
        uint256 payout = m.claim();
        assertLe(payout, h, "claim exceeded token balance");

        vm.prank(creator);
        m.claim();
        assertLt(cst.balanceOf(address(m)), 4, "more than dust stuck");
    }

    /// Markets on the same round are fully independent.
    function test_parallelMarketsAreIndependent() public {
        GestureMarket other = _deployMarket(MIN, MAX, FEE_BPS, LIQ);

        vm.startPrank(alice);
        cst.approve(address(other), type(uint256).max);
        market.betHigher(5_000e18, 0);
        vm.stopPrank();

        assertEq(other.reserveHigher(), LIQ, "sibling market reserves touched");
        assertEq(other.reserveLower(), LIQ);
        assertEq(other.predictedCount(), (MIN + MAX) / 2);

        _endRoundWith(900);
        market.resolve();
        other.resolve();
        assertEq(market.payoutPerHigher(), other.payoutPerHigher(), "same outcome, same fraction");
    }

    /// Trading stays impossible after resolution, forever.
    function test_noTradingAfterResolution() public {
        _endRoundWith(800);
        market.resolve();

        vm.startPrank(alice);
        vm.expectRevert(GestureMarket.TradingClosed.selector);
        market.betHigher(1e18, 0);
        vm.expectRevert(GestureMarket.TradingClosed.selector);
        market.betLower(1e18, 0);
        vm.expectRevert(GestureMarket.TradingClosed.selector);
        market.mintSets(1e18);
        vm.expectRevert(GestureMarket.TradingClosed.selector);
        market.redeemSets(1e18);
        vm.stopPrank();
    }
}

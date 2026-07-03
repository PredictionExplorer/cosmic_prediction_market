// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GestureMarket} from "../src/GestureMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";
import {MarketTestBase} from "./utils/MarketTestBase.sol";

/// @dev Exposes the internal AMM math for direct property fuzzing.
contract MarketHarness is GestureMarket {
    constructor(ICosmicSignatureGame game_) GestureMarket(game_, 0, 1_000, 0, 1e18) {}

    function exposedBuyAmount(uint256 reserveOut, uint256 reserveIn, uint256 net) external pure returns (uint256) {
        return _buyAmount(reserveOut, reserveIn, net);
    }
}

/// @notice Property-based fuzz tests. Every test states an economic or safety
/// property that must hold for ALL inputs, not just hand-picked examples.
/// Run long campaigns with: FOUNDRY_PROFILE=heavy forge test
contract GestureMarketFuzzTest is MarketTestBase {
    MarketHarness internal harness;

    function setUp() public override {
        super.setUp();
        cst.mint(address(this), 1e18);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        cst.approve(predicted, type(uint256).max);
        harness = new MarketHarness(ICosmicSignatureGame(address(game)));
    }

    // ------------------------------------------------------------------
    // Pure AMM math: _buyAmount holds its safety properties for any reserves
    // ------------------------------------------------------------------

    /// The pool must never oversend (post-trade reserve >= 1), never lose value
    /// (x*y=k never decreases), and one outcome token can never cost more than
    /// 1 CST (tokensOut >= net).
    function testFuzz_buyAmountSafety(uint256 reserveOut, uint256 reserveIn, uint256 net) public view {
        reserveOut = bound(reserveOut, 1, 1e33);
        reserveIn = bound(reserveIn, 1, 1e33);
        net = bound(net, 0, 1e33);

        uint256 tokensOut = harness.exposedBuyAmount(reserveOut, reserveIn, net);

        uint256 newReserveOut = reserveOut + net - tokensOut;
        assertGe(newReserveOut, 1, "pool reserve can never be emptied");
        assertGe(newReserveOut * (reserveIn + net), reserveOut * reserveIn, "constant product must never decrease");
        assertGe(tokensOut, net, "an outcome token can never cost more than 1 CST");
    }

    /// Paying more must never yield fewer tokens.
    function testFuzz_buyAmountMonotoneInInput(uint256 reserveOut, uint256 reserveIn, uint256 net1, uint256 net2)
        public
        view
    {
        reserveOut = bound(reserveOut, 1, 1e33);
        reserveIn = bound(reserveIn, 1, 1e33);
        net1 = bound(net1, 0, 1e33);
        net2 = bound(net2, net1, 1e33);

        assertGe(
            harness.exposedBuyAmount(reserveOut, reserveIn, net2),
            harness.exposedBuyAmount(reserveOut, reserveIn, net1),
            "buy amount must be monotone in input"
        );
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    function testFuzz_constructorAcceptsAllValidParams(uint256 min, uint256 max, uint256 feeBps, uint256 liq) public {
        max = bound(max, 1, 1e12);
        min = bound(min, 0, max - 1);
        feeBps = bound(feeBps, 0, 1_000);
        liq = bound(liq, 1, 1e27);

        GestureMarket m = _deployMarket(min, max, feeBps, liq);

        assertEq(m.minCount(), min);
        assertEq(m.maxCount(), max);
        assertEq(m.reserveHigher(), liq);
        assertEq(m.reserveLower(), liq);
        assertEq(cst.balanceOf(address(m)), liq);
        uint256 predicted = m.predictedCount();
        assertGe(predicted, min);
        assertLe(predicted, max);
    }

    function testFuzz_constructorRejectsInvalidRange(uint256 min, uint256 max) public {
        min = bound(min, 0, 1e12);
        max = bound(max, 0, min); // max <= min is always invalid
        cst.mint(creator, LIQ);
        vm.expectRevert(GestureMarket.InvalidParams.selector);
        vm.prank(creator);
        new GestureMarket(ICosmicSignatureGame(address(game)), min, max, FEE_BPS, LIQ);
    }

    function testFuzz_constructorRejectsOversizedRange(uint256 max) public {
        max = bound(max, 1e12 + 1, type(uint256).max);
        cst.mint(creator, LIQ);
        vm.expectRevert(GestureMarket.InvalidParams.selector);
        vm.prank(creator);
        new GestureMarket(ICosmicSignatureGame(address(game)), 0, max, FEE_BPS, LIQ);
    }

    function testFuzz_constructorRejectsExcessiveFee(uint256 feeBps) public {
        feeBps = bound(feeBps, 1_001, type(uint256).max);
        cst.mint(creator, LIQ);
        vm.expectRevert(GestureMarket.InvalidParams.selector);
        vm.prank(creator);
        new GestureMarket(ICosmicSignatureGame(address(game)), MIN, MAX, feeBps, LIQ);
    }

    // ------------------------------------------------------------------
    // Trading properties
    // ------------------------------------------------------------------

    /// Betting HIGHER can only move the prediction up (strictly, for bets big
    /// enough to register at integer granularity), and never out of range.
    function testFuzz_betHigherMovesPredictionUpWithinRange(uint256 amount) public {
        amount = bound(amount, 1, 500_000e18);
        uint256 before = market.predictedCount();

        vm.prank(alice);
        market.betHigher(amount, 0);

        uint256 predictedAfter = market.predictedCount();
        if (amount >= 100e18) assertGt(predictedAfter, before, "sized bet must move prediction");
        else assertGe(predictedAfter, before, "prediction can never move against the bet");
        assertLe(predictedAfter, MAX, "prediction can never exceed maxCount");
    }

    function testFuzz_betLowerMovesPredictionDownWithinRange(uint256 amount) public {
        amount = bound(amount, 1, 500_000e18);
        uint256 before = market.predictedCount();

        vm.prank(alice);
        market.betLower(amount, 0);

        uint256 predictedAfter = market.predictedCount();
        if (amount >= 100e18) assertLt(predictedAfter, before, "sized bet must move prediction");
        else assertLe(predictedAfter, before, "prediction can never move against the bet");
        assertGe(predictedAfter, MIN, "prediction can never fall below minCount");
    }

    /// After ANY sequence of bets the prediction stays in [minCount, maxCount],
    /// k never decreases, and reserves never empty.
    function testFuzz_arbitraryBetSequenceKeepsPoolHealthy(uint256[4] memory amounts, uint8 dirMask) public {
        uint256 kBefore = market.reserveHigher() * market.reserveLower();

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = bound(amounts[i], 1, 250_000e18);
            vm.prank(alice);
            if ((dirMask >> i) & 1 == 1) market.betHigher(amount, 0);
            else market.betLower(amount, 0);

            uint256 predicted = market.predictedCount();
            assertGe(predicted, MIN, "prediction below range");
            assertLe(predicted, MAX, "prediction above range");
            assertGe(market.reserveHigher(), 1, "higher reserve emptied");
            assertGe(market.reserveLower(), 1, "lower reserve emptied");

            uint256 k = market.reserveHigher() * market.reserveLower();
            assertGe(k, kBefore, "k decreased");
            kBefore = k;
        }
    }

    /// Quotes must exactly equal what the bet actually pays, from any pool state.
    function testFuzz_quotesMatchBetsFromAnyState(uint256 skew, bool skewHigher, uint256 amount) public {
        skew = bound(skew, 1, 200_000e18);
        amount = bound(amount, 1, 200_000e18);

        vm.prank(bob);
        if (skewHigher) market.betHigher(skew, 0);
        else market.betLower(skew, 0);

        uint256 quotedHigher = market.quoteBetHigher(amount);
        uint256 quotedLower = market.quoteBetLower(amount);

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        assertEq(market.betHigher(amount, 0), quotedHigher, "higher quote mismatch");
        vm.revertToState(snap);
        vm.prank(alice);
        assertEq(market.betLower(amount, 0), quotedLower, "lower quote mismatch");
    }

    /// A bet split into two parts must give (near) identical tokens as one bet:
    /// the AMM is path-independent up to integer rounding, so ordering games
    /// gain nothing.
    function testFuzz_splitBetEquivalentToSingleBet(uint256 a, uint256 b) public {
        a = bound(a, 1e18, 100_000e18);
        b = bound(b, 1e18, 100_000e18);

        uint256 snap = vm.snapshotState();
        vm.startPrank(alice);
        uint256 split = market.betHigher(a, 0) + market.betHigher(b, 0);
        vm.stopPrank();

        vm.revertToState(snap);
        vm.prank(alice);
        uint256 single = market.betHigher(a + b, 0);

        assertApproxEqAbs(split, single, 4, "path dependence beyond rounding");
    }

    /// Slippage protection: any minTokensOut above the true output must revert.
    function testFuzz_slippageGuardAlwaysEnforced(uint256 amount, uint256 excess) public {
        amount = bound(amount, 1, 500_000e18);
        excess = bound(excess, 1, type(uint128).max);
        uint256 quoted = market.quoteBetHigher(amount);

        vm.expectRevert(GestureMarket.Slippage.selector);
        vm.prank(alice);
        market.betHigher(amount, quoted + excess);
    }

    function testFuzz_mintRedeemExactRoundtrip(uint256 amount) public {
        amount = bound(amount, 0, 1_000_000e18);
        uint256 before = cst.balanceOf(alice);

        vm.startPrank(alice);
        market.mintSets(amount);
        market.redeemSets(amount);
        vm.stopPrank();

        assertEq(cst.balanceOf(alice), before, "mint+redeem must be exactly free");
        assertEq(market.higherBalance(alice), 0);
        assertEq(market.lowerBalance(alice), 0);
    }

    function testFuzz_cannotRedeemMoreThanOwned(uint256 amount, uint256 excess) public {
        amount = bound(amount, 0, 1_000_000e18 - 1);
        excess = bound(excess, 1, type(uint128).max);

        vm.startPrank(alice);
        market.mintSets(amount);
        vm.expectRevert(); // arithmetic underflow
        market.redeemSets(amount + excess);
        vm.stopPrank();
    }

    /// No money pump: whatever combination of betting both sides and redeeming
    /// pairs a user runs pre-resolution — even against a pool someone else has
    /// skewed — they can never withdraw more CST than they put in.
    function testFuzz_noProfitExtractionPreResolution(uint256 skew, bool skewHigher, uint256 a, uint256 b) public {
        skew = bound(skew, 1, 500_000e18);
        a = bound(a, 1, 400_000e18);
        b = bound(b, 1, 400_000e18);

        vm.prank(bob);
        if (skewHigher) market.betHigher(skew, 0);
        else market.betLower(skew, 0);

        uint256 aliceStart = cst.balanceOf(alice);

        vm.startPrank(alice);
        market.betHigher(a, 0);
        market.betLower(b, 0);
        uint256 h = market.higherBalance(alice);
        uint256 l = market.lowerBalance(alice);
        market.redeemSets(h < l ? h : l);
        vm.stopPrank();

        assertLe(cst.balanceOf(alice), aliceStart, "pre-resolution profit extraction");
    }

    /// Even absurdly large bets cannot drain the pool or push the prediction
    /// out of range, and can never take more tokens than net input + reserve.
    function testFuzz_extremeBetsCannotBreakPool(uint256 amount, bool higher) public {
        amount = bound(amount, 1e24, 1e27); // 1M to 1B CST against a 10k pool
        cst.mint(alice, amount);

        vm.prank(alice);
        uint256 tokensOut = higher ? market.betHigher(amount, 0) : market.betLower(amount, 0);

        uint256 net = amount - amount * FEE_BPS / 10_000;
        assertLe(tokensOut, net + LIQ, "took more than net input plus full reserve");
        assertGe(market.reserveHigher(), 1);
        assertGe(market.reserveLower(), 1);
        uint256 predicted = market.predictedCount();
        assertGe(predicted, MIN);
        assertLe(predicted, MAX);
    }

    /// Dust-sized bets must not mint free tokens: with equal reserves the
    /// marginal price is 0.5, so output can never exceed ~2x input.
    function testFuzz_dustBetsYieldNoFreeTokens(uint256 amount) public {
        amount = bound(amount, 1, 1e6);
        vm.prank(alice);
        uint256 tokensOut = market.betHigher(amount, 0);
        assertLe(tokensOut, 2 * amount + 2, "dust bet minted free tokens");
    }

    // ------------------------------------------------------------------
    // Fees
    // ------------------------------------------------------------------

    /// Accrued fees must equal the per-bet floor formula exactly, and reach the
    /// creator in full at resolution.
    function testFuzz_feeAccountingExact(uint256 a, uint256 b) public {
        a = bound(a, 1, 500_000e18);
        b = bound(b, 1, 500_000e18);

        vm.prank(alice);
        market.betHigher(a, 0);
        vm.prank(bob);
        market.betLower(b, 0);

        uint256 expectedFees = a * FEE_BPS / 10_000 + b * FEE_BPS / 10_000;
        assertEq(market.feesAccrued(), expectedFees, "fee accrual mismatch");

        _endRoundWith(700);
        market.resolve();

        assertEq(market.feesAccrued(), 0, "fees must be flushed at resolve");
        assertEq(cst.balanceOf(creator), expectedFees, "creator must receive exact fees");
    }

    /// A zero-fee market accrues nothing regardless of volume.
    function testFuzz_zeroFeeMarketAccruesNothing(uint256 amount) public {
        amount = bound(amount, 1, 500_000e18);
        GestureMarket zeroFee = _deployMarket(MIN, MAX, 0, LIQ);
        vm.startPrank(alice);
        cst.approve(address(zeroFee), type(uint256).max);
        zeroFee.betHigher(amount, 0);
        vm.stopPrank();
        assertEq(zeroFee.feesAccrued(), 0);
    }

    // ------------------------------------------------------------------
    // Resolution properties
    // ------------------------------------------------------------------

    /// The payout fraction must match the clamp formula exactly and stay in [0, 1e18].
    function testFuzz_payoutFractionCorrectForAnyCount(uint256 finalCount) public {
        _endRoundWith(finalCount);
        market.resolve();

        uint256 f = market.payoutPerHigher();
        assertEq(f, _expectedPayoutPerHigher(finalCount, MIN, MAX), "payout formula mismatch");
        assertLe(f, 1e18, "payout fraction above 100%");
        assertEq(market.finalGestureCount(), finalCount, "raw count must be stored unclamped");
    }

    /// More gestures can never pay HIGHER holders less.
    function testFuzz_payoutMonotoneInFinalCount(uint256 c1, uint256 c2) public {
        c1 = bound(c1, 0, 5_000);
        c2 = bound(c2, c1, 5_000);

        uint256 snap = vm.snapshotState();
        _endRoundWith(c1);
        market.resolve();
        uint256 f1 = market.payoutPerHigher();

        vm.revertToState(snap);
        _endRoundWith(c2);
        market.resolve();
        uint256 f2 = market.payoutPerHigher();

        assertLe(f1, f2, "payout must be monotone in the gesture count");
    }

    /// Resolution must work no matter how many rounds the game advances past ours,
    /// and trading must stay closed for all of them.
    function testFuzz_resolveWorksForAnyRoundAdvance(uint256 jump, uint256 finalCount) public {
        jump = bound(jump, 1, 10_000);
        finalCount = bound(finalCount, 0, 100_000);

        game.setNumBids(ROUND, finalCount);
        game.setRoundNum(ROUND + jump);

        vm.expectRevert(GestureMarket.TradingClosed.selector);
        vm.prank(alice);
        market.betHigher(1e18, 0);

        market.resolve();
        assertTrue(market.resolved());
        assertEq(market.payoutPerHigher(), _expectedPayoutPerHigher(finalCount, MIN, MAX));
    }

    /// A claim is always a convex combination of the two token balances:
    /// min(h, l) - 1 <= payout <= max(h, l).
    function testFuzz_claimBoundedByTokenBalances(uint256 a, uint256 b, uint256 finalCount) public {
        a = bound(a, 1, 400_000e18);
        b = bound(b, 1, 400_000e18);

        vm.startPrank(alice);
        market.betHigher(a, 0);
        market.betLower(b, 0);
        vm.stopPrank();

        uint256 h = market.higherBalance(alice);
        uint256 l = market.lowerBalance(alice);

        _endRoundWith(bound(finalCount, 0, 5_000));
        market.resolve();

        vm.prank(alice);
        uint256 payout = market.claim();

        assertLe(payout, h > l ? h : l, "payout above both token balances");
        assertGe(payout + 1, h < l ? h : l, "payout below both token balances");
    }

    // ------------------------------------------------------------------
    // Full-lifecycle conservation
    // ------------------------------------------------------------------

    /// The flagship property: for any fee, any mix of actors, bet directions,
    /// set minting/redeeming, and any final count, the market pays everyone in
    /// full and retains only integer-division dust. CST can never be created
    /// and never gets stuck beyond a few wei.
    function testFuzz_lifecycleConservation(
        uint256[3] memory betAmounts,
        uint8 dirMask,
        uint256 mintAmount,
        uint256 finalCount,
        uint256 feeBps
    ) public {
        feeBps = bound(feeBps, 0, 1_000);
        GestureMarket m = _deployMarket(MIN, MAX, feeBps, LIQ);

        address[3] memory actors = [alice, bob, carol];
        uint256 totalIn = LIQ;
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 amount = bound(betAmounts[i], 1, 300_000e18);
            vm.startPrank(actors[i]);
            cst.approve(address(m), type(uint256).max);
            if ((dirMask >> i) & 1 == 1) m.betHigher(amount, 0);
            else m.betLower(amount, 0);
            vm.stopPrank();
            totalIn += amount;
        }

        // Carol also mints sets and redeems half, exercising the set paths.
        mintAmount = bound(mintAmount, 2, 100_000e18);
        vm.startPrank(carol);
        m.mintSets(mintAmount);
        m.redeemSets(mintAmount / 2);
        vm.stopPrank();
        totalIn += mintAmount - mintAmount / 2;

        assertEq(cst.balanceOf(address(m)), totalIn, "pre-resolution balance must equal net inflows");

        game.setNumBids(ROUND, bound(finalCount, 0, 5_000));
        game.setRoundNum(ROUND + 1);
        uint256 feesBefore = m.feesAccrued();
        m.resolve();

        uint256 totalOut = feesBefore;
        for (uint256 i = 0; i < actors.length; i++) {
            vm.prank(actors[i]);
            totalOut += m.claim();
        }
        vm.prank(creator);
        totalOut += m.claim();

        assertLe(totalOut, totalIn, "market paid out more CST than it received");
        assertLt(totalIn - totalOut, 8, "more than dust got stuck");
        assertEq(cst.balanceOf(address(m)), totalIn - totalOut, "balance accounting broken");
    }
}

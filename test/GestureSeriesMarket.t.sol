// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GestureSeriesMarket} from "../src/GestureSeriesMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";
import {SeriesTestBase} from "./utils/SeriesTestBase.sol";

/// @notice Core unit tests: happy paths, guards, and known edge cases for
/// every external function of the series market.
contract GestureSeriesMarketTest is SeriesTestBase {
    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    function test_constructorState() public view {
        assertEq(address(market.game()), address(game));
        assertEq(address(market.cst()), address(cst));
        uint16[] memory tiers = market.feeTiers();
        assertEq(tiers.length, 3);
        assertEq(tiers[0], TIER_LOW);
        assertEq(tiers[1], TIER_MID);
        assertEq(tiers[2], TIER_HIGH);
    }

    function test_constructorRejectsBadParams() public {
        uint16[] memory tiers = _defaultTiers();

        // Zero game address.
        vm.expectRevert(GestureSeriesMarket.InvalidParams.selector);
        new GestureSeriesMarket(ICosmicSignatureGame(address(0)), tiers);

        // No tiers.
        vm.expectRevert(GestureSeriesMarket.InvalidParams.selector);
        new GestureSeriesMarket(ICosmicSignatureGame(address(game)), new uint16[](0));

        // Too many tiers.
        vm.expectRevert(GestureSeriesMarket.InvalidParams.selector);
        new GestureSeriesMarket(ICosmicSignatureGame(address(game)), new uint16[](6));

        // Zero fee tier.
        uint16[] memory zeroTier = new uint16[](1);
        zeroTier[0] = 0;
        vm.expectRevert(GestureSeriesMarket.InvalidParams.selector);
        new GestureSeriesMarket(ICosmicSignatureGame(address(game)), zeroTier);

        // Tier above the 10% cap.
        uint16[] memory bigTier = new uint16[](1);
        bigTier[0] = 1_001;
        vm.expectRevert(GestureSeriesMarket.InvalidParams.selector);
        new GestureSeriesMarket(ICosmicSignatureGame(address(game)), bigTier);

        // Not strictly ascending.
        uint16[] memory unsorted = new uint16[](2);
        unsorted[0] = 200;
        unsorted[1] = 200;
        vm.expectRevert(GestureSeriesMarket.InvalidParams.selector);
        new GestureSeriesMarket(ICosmicSignatureGame(address(game)), unsorted);
    }

    function test_constructorAcceptsBoundaryTiers() public {
        uint16[] memory tiers = new uint16[](5);
        tiers[0] = 1;
        tiers[1] = 10;
        tiers[2] = 100;
        tiers[3] = 500;
        tiers[4] = 1_000;
        GestureSeriesMarket m = new GestureSeriesMarket(ICosmicSignatureGame(address(game)), tiers);
        assertEq(m.feeTiers().length, 5);
    }

    // ------------------------------------------------------------------
    // Round initialization (lazy, via addLiquidity)
    // ------------------------------------------------------------------

    function test_firstAddLiquidityInitializesRound() public {
        vm.expectEmit(true, false, false, true);
        emit GestureSeriesMarket.RoundInitialized(ROUND, THRESHOLD);
        _seedPool(TIER_LOW, LIQ);

        (bool initialized,,, uint256 threshold,, bool active, bool decided) = market.roundState(ROUND);
        assertTrue(initialized);
        assertTrue(active);
        assertFalse(decided);
        assertEq(threshold, THRESHOLD, "threshold is the previous round's final count");
    }

    function test_cannotInitializeNonCurrentRound() public {
        vm.startPrank(lpAda);
        vm.expectRevert(GestureSeriesMarket.RoundNotActive.selector);
        market.addLiquidity(ROUND + 1, TIER_LOW, LIQ, 5_000, 0, NO_DEADLINE); // future
        vm.expectRevert(GestureSeriesMarket.RoundNotActive.selector);
        market.addLiquidity(ROUND - 1, TIER_LOW, LIQ, 5_000, 0, NO_DEADLINE); // past
        vm.stopPrank();
    }

    function test_cannotInitializeRoundZero() public {
        game.setRoundNum(0);
        vm.prank(lpAda);
        vm.expectRevert(GestureSeriesMarket.RoundNotActive.selector);
        market.addLiquidity(0, TIER_LOW, LIQ, 5_000, 0, NO_DEADLINE);
    }

    function test_cannotInitializeRoundWhoseOutcomeIsAlreadyDecided() public {
        _crossThreshold(); // count > threshold before anyone funded the market
        vm.prank(lpAda);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.addLiquidity(ROUND, TIER_LOW, LIQ, 5_000, 0, NO_DEADLINE);

        (bool initialized,,,,,,) = market.roundState(ROUND);
        assertFalse(initialized, "failed init must roll back entirely");
    }

    // ------------------------------------------------------------------
    // addLiquidity: opening a pool
    // ------------------------------------------------------------------

    function test_openPoolAtEvenOdds() public {
        uint256 shares = _seedPool(TIER_LOW, LIQ);

        (uint256 rY, uint256 rN) = _reserves(ROUND, TIER_LOW);
        assertEq(rY, LIQ);
        assertEq(rN, LIQ);
        assertEq(shares, LIQ - DEAD_SHARES, "dead shares deducted from the first LP");
        assertEq(_totalShares(ROUND, TIER_LOW), LIQ);
        (uint256 deadShares,) = market.lpPositionOf(ROUND, TIER_LOW, address(0));
        assertEq(deadShares, DEAD_SHARES, "dead shares locked at address(0)");
        assertEq(_yesBal(lpAda), 0, "no excess tokens at 50/50");
        assertEq(_noBal(lpAda), 0);
        assertEq(_probBps(ROUND, TIER_LOW), 5_000);
    }

    function test_openPoolAtSkewedOddsCreditsExcess() public {
        // 30% YES: full deposit on the YES reserve, scaled NO reserve, excess NO back.
        vm.prank(lpAda);
        market.addLiquidity(ROUND, TIER_LOW, LIQ, 3_000, 0, NO_DEADLINE);

        (uint256 rY, uint256 rN) = _reserves(ROUND, TIER_LOW);
        assertEq(rY, LIQ);
        assertEq(rN, LIQ * 3_000 / 7_000);
        assertEq(_yesBal(lpAda), 0);
        assertEq(_noBal(lpAda), LIQ - rN, "surplus NO stays with the LP");
        assertApproxEqAbs(_probBps(ROUND, TIER_LOW), 3_000, 1);

        // 70% YES mirrors it.
        vm.prank(lpBen);
        market.addLiquidity(ROUND, TIER_MID, LIQ, 7_000, 0, NO_DEADLINE);
        (rY, rN) = _reserves(ROUND, TIER_MID);
        assertEq(rN, LIQ);
        assertEq(rY, LIQ * 3_000 / 7_000);
        (uint256 benYes,) = market.balancesOf(ROUND, lpBen);
        assertEq(benYes, LIQ - rY, "surplus YES stays with the LP");
        assertApproxEqAbs(_probBps(ROUND, TIER_MID), 7_000, 1);
    }

    function test_openPoolGuards() public {
        vm.startPrank(lpAda);
        // Below the minimum initial liquidity.
        vm.expectRevert(GestureSeriesMarket.InsufficientLiquidity.selector);
        market.addLiquidity(ROUND, TIER_LOW, 1e15 - 1, 5_000, 0, NO_DEADLINE);
        // Probability outside [1%, 99%].
        vm.expectRevert(GestureSeriesMarket.InvalidParams.selector);
        market.addLiquidity(ROUND, TIER_LOW, LIQ, 99, 0, NO_DEADLINE);
        vm.expectRevert(GestureSeriesMarket.InvalidParams.selector);
        market.addLiquidity(ROUND, TIER_LOW, LIQ, 9_901, 0, NO_DEADLINE);
        // Unknown fee tier.
        vm.expectRevert(GestureSeriesMarket.InvalidFeeTier.selector);
        market.addLiquidity(ROUND, 123, LIQ, 5_000, 0, NO_DEADLINE);
        // Zero amount.
        vm.expectRevert(GestureSeriesMarket.InvalidParams.selector);
        market.addLiquidity(ROUND, TIER_LOW, 0, 5_000, 0, NO_DEADLINE);
        // Expired deadline.
        vm.expectRevert(GestureSeriesMarket.DeadlineExpired.selector);
        market.addLiquidity(ROUND, TIER_LOW, LIQ, 5_000, 0, block.timestamp - 1);
        // Share slippage guard.
        vm.expectRevert(GestureSeriesMarket.Slippage.selector);
        market.addLiquidity(ROUND, TIER_LOW, LIQ, 5_000, LIQ + 1, NO_DEADLINE);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // addLiquidity: joining a pool
    // ------------------------------------------------------------------

    function test_joinPoolAtCurrentRatio() public {
        _seedPool(TIER_LOW, LIQ);

        vm.prank(lpBen);
        uint256 shares = market.addLiquidity(ROUND, TIER_LOW, 5_000e18, 0, 0, NO_DEADLINE);

        assertEq(shares, 5_000e18, "50% of the pool's max reserve -> 50% of shares");
        (uint256 rY, uint256 rN) = _reserves(ROUND, TIER_LOW);
        assertEq(rY, LIQ + 5_000e18);
        assertEq(rN, LIQ + 5_000e18);
        assertEq(_yesBal(lpBen), 0, "no excess in a balanced pool");
        assertEq(_noBal(lpBen), 0);
    }

    function test_joinSkewedPoolPreservesPriceAndCreditsExcess() public {
        _seedPool(TIER_LOW, LIQ);
        // Skew the pool with a bet first.
        vm.prank(alice);
        market.betYes(ROUND, TIER_LOW, 4_000e18, 0, NO_DEADLINE);
        uint256 probBefore = _probBps(ROUND, TIER_LOW);
        (uint256 rYBefore, uint256 rNBefore) = _reserves(ROUND, TIER_LOW);

        vm.prank(lpBen);
        market.addLiquidity(ROUND, TIER_LOW, 6_000e18, 0, 0, NO_DEADLINE);

        assertApproxEqAbs(_probBps(ROUND, TIER_LOW), probBefore, 1, "join must not move the price");
        (uint256 rYAfter, uint256 rNAfter) = _reserves(ROUND, TIER_LOW);
        // The max reserve grows by exactly the deposit; the other proportionally.
        uint256 m = rYBefore > rNBefore ? rYBefore : rNBefore;
        assertEq((rYAfter - rYBefore) + (_yesBal(lpBen)), 6_000e18, "every YES accounted for");
        assertEq((rNAfter - rNBefore) + (_noBal(lpBen)), 6_000e18, "every NO accounted for");
        // One of the two sides deposits in full (the max side).
        if (rYBefore == m) assertEq(rYAfter - rYBefore, 6_000e18);
        else assertEq(rNAfter - rNBefore, 6_000e18);
    }

    function test_joinThenRemoveNeverProfits() public {
        _seedPool(TIER_LOW, LIQ);
        vm.prank(alice);
        market.betYes(ROUND, TIER_LOW, 3_333e18, 0, NO_DEADLINE);

        uint256 before = cst.balanceOf(lpBen);
        vm.startPrank(lpBen);
        uint256 shares = market.addLiquidity(ROUND, TIER_LOW, 1_000e18, 0, 0, NO_DEADLINE);
        market.removeLiquidity(ROUND, TIER_LOW, shares, 0, 0, NO_DEADLINE);
        // Convert everything liquid back to CST: redeem the paired portion.
        (uint256 yes, uint256 no) = market.balancesOf(ROUND, lpBen);
        market.redeemSets(ROUND, yes < no ? yes : no);
        vm.stopPrank();

        (uint256 yesLeft, uint256 noLeft) = market.balancesOf(ROUND, lpBen);
        // Whatever residual one-sided tokens remain are worth at most 1 CST each;
        // even crediting them in full, the roundtrip cannot profit.
        uint256 residualUpperBound = yesLeft > noLeft ? yesLeft : noLeft;
        assertLe(cst.balanceOf(lpBen) + 1, before + residualUpperBound + 1, "add/remove roundtrip minted value");
        assertLe(cst.balanceOf(lpBen), before, "roundtrip must not pay out more CST than deposited");
    }

    // ------------------------------------------------------------------
    // Betting
    // ------------------------------------------------------------------

    function test_betYesMovesProbabilityUp() public {
        _seedPool(TIER_LOW, LIQ);
        uint256 before = _probBps(ROUND, TIER_LOW);

        vm.prank(alice);
        uint256 tokensOut = market.betYes(ROUND, TIER_LOW, 2_000e18, 0, NO_DEADLINE);

        assertGt(_probBps(ROUND, TIER_LOW), before, "YES probability should rise");
        assertGt(tokensOut, 2_000e18 - 2_000e18 * uint256(TIER_LOW) / BPS, "always get more tokens than net CST");
        assertEq(_yesBal(alice), tokensOut);
        assertEq(_noBal(alice), 0);
    }

    function test_betNoMovesProbabilityDown() public {
        _seedPool(TIER_LOW, LIQ);
        uint256 before = _probBps(ROUND, TIER_LOW);

        vm.prank(bob);
        uint256 tokensOut = market.betNo(ROUND, TIER_LOW, 2_000e18, 0, NO_DEADLINE);

        assertLt(_probBps(ROUND, TIER_LOW), before, "YES probability should fall");
        assertEq(_noBal(bob), tokensOut);
        assertEq(_yesBal(bob), 0);
    }

    function test_quotesMatchActualBets() public {
        _seedAllPools(LIQ);
        uint256 quotedYes = market.quoteBetYes(ROUND, TIER_MID, 1_234e18);
        vm.prank(alice);
        assertEq(market.betYes(ROUND, TIER_MID, 1_234e18, 0, NO_DEADLINE), quotedYes);

        uint256 quotedNo = market.quoteBetNo(ROUND, TIER_HIGH, 777e18);
        vm.prank(bob);
        assertEq(market.betNo(ROUND, TIER_HIGH, 777e18, 0, NO_DEADLINE), quotedNo);
    }

    function test_betGuards() public {
        _seedPool(TIER_LOW, LIQ);
        uint256 quoted = market.quoteBetYes(ROUND, TIER_LOW, 1_000e18);

        vm.startPrank(alice);
        // Slippage.
        vm.expectRevert(GestureSeriesMarket.Slippage.selector);
        market.betYes(ROUND, TIER_LOW, 1_000e18, quoted + 1, NO_DEADLINE);
        // Deadline.
        vm.expectRevert(GestureSeriesMarket.DeadlineExpired.selector);
        market.betYes(ROUND, TIER_LOW, 1_000e18, 0, block.timestamp - 1);
        // Zero amount.
        vm.expectRevert(GestureSeriesMarket.InvalidParams.selector);
        market.betYes(ROUND, TIER_LOW, 0, 0, NO_DEADLINE);
        // Unfunded tier: no liquidity there yet.
        vm.expectRevert(GestureSeriesMarket.InsufficientLiquidity.selector);
        market.betYes(ROUND, TIER_MID, 1_000e18, 0, NO_DEADLINE);
        // Uninitialized round.
        vm.expectRevert(GestureSeriesMarket.RoundNotInitialized.selector);
        market.betYes(ROUND + 1, TIER_LOW, 1_000e18, 0, NO_DEADLINE);
        vm.stopPrank();
    }

    function test_betBestRoutesToBestExecution() public {
        _seedAllPools(LIQ);
        // With identical reserves everywhere, the lowest fee wins.
        (uint16 tier, uint256 quoted) = market.quoteBetYesBest(ROUND, 1_000e18);
        assertEq(tier, TIER_LOW);
        assertEq(quoted, market.quoteBetYes(ROUND, TIER_LOW, 1_000e18));

        // Skew the low-fee pool so YES is expensive there; routing must move away.
        vm.prank(bob);
        market.betYes(ROUND, TIER_LOW, 8_000e18, 0, NO_DEADLINE);
        (uint16 tierAfter,) = market.quoteBetYesBest(ROUND, 1_000e18);
        assertTrue(tierAfter != TIER_LOW, "router must avoid the skewed pool");

        // The executed best bet matches its quote and beats every single tier.
        (, uint256 bestQuote) = market.quoteBetYesBest(ROUND, 1_000e18);
        vm.prank(alice);
        (uint16 executedTier, uint256 out) = market.betYesBest(ROUND, 1_000e18, 0, NO_DEADLINE);
        assertEq(executedTier, tierAfter);
        assertEq(out, bestQuote);
        assertGe(out, market.quoteBetYes(ROUND, TIER_MID, 1_000e18));
    }

    function test_betOnUnfundedTierReverts() public {
        _seedPool(TIER_LOW, LIQ); // initializes the round, funds only one tier
        vm.startPrank(alice);
        vm.expectRevert(GestureSeriesMarket.InsufficientLiquidity.selector);
        market.betYes(ROUND, TIER_MID, 1_000e18, 0, NO_DEADLINE);
        vm.expectRevert(GestureSeriesMarket.InsufficientLiquidity.selector);
        market.betNo(ROUND, TIER_HIGH, 1_000e18, 0, NO_DEADLINE);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Sets
    // ------------------------------------------------------------------

    function test_mintRedeemSetsRoundtripIsFree() public {
        _seedPool(TIER_LOW, LIQ);
        uint256 before = cst.balanceOf(alice);

        vm.startPrank(alice);
        market.mintSets(ROUND, 100e18);
        assertEq(_yesBal(alice), 100e18);
        assertEq(_noBal(alice), 100e18);
        market.redeemSets(ROUND, 100e18);
        vm.stopPrank();

        assertEq(cst.balanceOf(alice), before, "sets roundtrip is exactly free");
        assertEq(_yesBal(alice), 0);
        assertEq(_noBal(alice), 0);
    }

    function test_setsGuards() public {
        vm.startPrank(alice);
        // Round not initialized yet.
        vm.expectRevert(GestureSeriesMarket.RoundNotInitialized.selector);
        market.mintSets(ROUND, 1e18);
        vm.stopPrank();

        _seedPool(TIER_LOW, LIQ);

        vm.startPrank(alice);
        vm.expectRevert(GestureSeriesMarket.InvalidParams.selector);
        market.mintSets(ROUND, 0);
        market.mintSets(ROUND, 10e18);
        // Cannot redeem more than the paired amount.
        vm.expectRevert(GestureSeriesMarket.InsufficientShares.selector);
        market.redeemSets(ROUND, 10e18 + 1);
        vm.stopPrank();
    }

    function test_exitBetEarlyViaOppositeSidePlusRedeem() public {
        _seedPool(TIER_LOW, LIQ);
        vm.startPrank(alice);
        uint256 yesOut = market.betYes(ROUND, TIER_LOW, 1_000e18, 0, NO_DEADLINE);
        uint256 noOut = market.betNo(ROUND, TIER_LOW, 1_000e18, 0, NO_DEADLINE);
        uint256 pairs = yesOut < noOut ? yesOut : noOut;
        market.redeemSets(ROUND, pairs);
        vm.stopPrank();

        assertEq(_yesBal(alice), yesOut - pairs);
        assertEq(_noBal(alice), noOut - pairs);
    }

    function test_redeemSetsStillWorksAfterRoundEndsUnresolved() public {
        _seedPool(TIER_LOW, LIQ);
        vm.prank(alice);
        market.mintSets(ROUND, 50e18);

        _endRoundWith(THRESHOLD); // round over, nobody resolved yet

        vm.prank(alice);
        market.redeemSets(ROUND, 50e18);
        assertEq(_yesBal(alice), 0);
    }

    // ------------------------------------------------------------------
    // Trading halts
    // ------------------------------------------------------------------

    function test_tradingClosedOnceRoundEnds() public {
        _seedPool(TIER_LOW, LIQ);
        _endRoundWith(700);

        vm.startPrank(alice);
        vm.expectRevert(GestureSeriesMarket.RoundNotActive.selector);
        market.betYes(ROUND, TIER_LOW, 1e18, 0, NO_DEADLINE);
        vm.expectRevert(GestureSeriesMarket.RoundNotActive.selector);
        market.betNoBest(ROUND, 1e18, 0, NO_DEADLINE);
        vm.expectRevert(GestureSeriesMarket.RoundNotActive.selector);
        market.mintSets(ROUND, 1e18);
        vm.stopPrank();
        vm.prank(lpBen);
        vm.expectRevert(GestureSeriesMarket.RoundNotActive.selector);
        market.addLiquidity(ROUND, TIER_LOW, 1_000e18, 0, 0, NO_DEADLINE);
    }

    function test_tradingHaltsTheInstantTheOutcomeIsDecided() public {
        _seedPool(TIER_LOW, LIQ);
        _crossThreshold(); // count > threshold, round still live

        vm.startPrank(alice);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.betYes(ROUND, TIER_LOW, 1e18, 0, NO_DEADLINE);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.betNo(ROUND, TIER_LOW, 1e18, 0, NO_DEADLINE);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.betYesBest(ROUND, 1e18, 0, NO_DEADLINE);
        vm.stopPrank();

        vm.prank(lpBen);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.addLiquidity(ROUND, TIER_LOW, 1_000e18, 0, 0, NO_DEADLINE);

        // LP exit remains open — liquidity is never trapped.
        (uint256 shares,) = market.lpPositionOf(ROUND, TIER_LOW, lpAda);
        vm.prank(lpAda);
        market.removeLiquidity(ROUND, TIER_LOW, shares / 2, 0, 0, NO_DEADLINE);
    }

    // ------------------------------------------------------------------
    // Resolution
    // ------------------------------------------------------------------

    function test_resolveRevertsWhileUncertain() public {
        _seedPool(TIER_LOW, LIQ);
        vm.expectRevert(GestureSeriesMarket.NotResolvable.selector);
        market.resolve(ROUND);
    }

    function test_resolveUninitializedRoundReverts() public {
        vm.expectRevert(GestureSeriesMarket.RoundNotInitialized.selector);
        market.resolve(ROUND);
    }

    function test_resolveAfterRoundEndYesWins() public {
        _seedPool(TIER_LOW, LIQ);
        _endRoundWith(THRESHOLD + 123);

        vm.expectEmit(true, false, false, true);
        emit GestureSeriesMarket.Resolved(ROUND, THRESHOLD + 123, true);
        market.resolve(ROUND);

        (, bool resolved, bool yesWon,,,,) = market.roundState(ROUND);
        assertTrue(resolved);
        assertTrue(yesWon);
    }

    function test_resolveAfterRoundEndNoWins() public {
        _seedPool(TIER_LOW, LIQ);
        _endRoundWith(THRESHOLD - 1);
        market.resolve(ROUND);
        (,, bool yesWon,,,,) = market.roundState(ROUND);
        assertFalse(yesWon);
    }

    function test_tieMeansNoWins() public {
        _seedPool(TIER_LOW, LIQ);
        _endRoundWith(THRESHOLD); // exactly equal
        market.resolve(ROUND);
        (,, bool yesWon,,,,) = market.roundState(ROUND);
        assertFalse(yesWon, "strictly greater required: a tie pays NO");
    }

    function test_earlyResolveTheMomentThresholdIsCrossed() public {
        _seedPool(TIER_LOW, LIQ);
        _crossThreshold(); // round still live!

        market.resolve(ROUND);
        (, bool resolved, bool yesWon,,, bool active,) = market.roundState(ROUND);
        assertTrue(resolved);
        assertTrue(yesWon);
        assertTrue(active, "resolved early while the round is still running");
    }

    function test_noEarlyResolveForNo() public {
        _seedPool(TIER_LOW, LIQ);
        game.setNumBids(ROUND, THRESHOLD); // equal is not strictly greater
        vm.expectRevert(GestureSeriesMarket.NotResolvable.selector);
        market.resolve(ROUND);
    }

    function test_resolveOnlyOnce() public {
        _seedPool(TIER_LOW, LIQ);
        _endRoundWith(900);
        market.resolve(ROUND);
        vm.expectRevert(GestureSeriesMarket.AlreadyResolved.selector);
        market.resolve(ROUND);
    }

    function test_nothingTradesAfterResolution() public {
        _seedPool(TIER_LOW, LIQ);
        vm.prank(alice);
        market.mintSets(ROUND, 10e18);
        _crossThreshold();
        market.resolve(ROUND);

        vm.startPrank(alice);
        vm.expectRevert(GestureSeriesMarket.AlreadyResolved.selector);
        market.betYes(ROUND, TIER_LOW, 1e18, 0, NO_DEADLINE);
        vm.expectRevert(GestureSeriesMarket.AlreadyResolved.selector);
        market.mintSets(ROUND, 1e18);
        vm.expectRevert(GestureSeriesMarket.AlreadyResolved.selector);
        market.redeemSets(ROUND, 1e18);
        vm.stopPrank();
        vm.prank(lpBen);
        vm.expectRevert(GestureSeriesMarket.AlreadyResolved.selector);
        market.addLiquidity(ROUND, TIER_LOW, 1_000e18, 0, 0, NO_DEADLINE);
    }

    // ------------------------------------------------------------------
    // Claims
    // ------------------------------------------------------------------

    function test_claimBeforeResolveReverts() public {
        _seedPool(TIER_LOW, LIQ);
        vm.expectRevert(GestureSeriesMarket.NotResolved.selector);
        vm.prank(alice);
        market.claim(ROUND);
    }

    function test_claimPaysWinnersOneToOneAndLosersZero() public {
        _seedPool(TIER_LOW, LIQ);
        vm.prank(alice);
        uint256 aliceYes = market.betYes(ROUND, TIER_LOW, 2_000e18, 0, NO_DEADLINE);
        vm.prank(bob);
        uint256 bobNo = market.betNo(ROUND, TIER_LOW, 1_500e18, 0, NO_DEADLINE);

        _endRoundWith(THRESHOLD + 500); // YES wins
        market.resolve(ROUND);

        uint256 aliceBefore = cst.balanceOf(alice);
        vm.prank(alice);
        assertEq(market.claim(ROUND), aliceYes, "1 CST per winning token");
        assertEq(cst.balanceOf(alice) - aliceBefore, aliceYes);
        assertGt(aliceYes, 2_000e18, "winning YES bet beats its cost");

        vm.prank(bob);
        assertEq(market.claim(ROUND), 0, "losing tokens pay nothing");
        assertGt(bobNo, 0);
        assertEq(_noBal(bob), 0, "losing balance zeroed too");
    }

    function test_claimIsIdempotent() public {
        _seedPool(TIER_LOW, LIQ);
        vm.prank(alice);
        market.betYes(ROUND, TIER_LOW, 1_000e18, 0, NO_DEADLINE);
        _endRoundWith(THRESHOLD + 1);
        market.resolve(ROUND);

        vm.prank(alice);
        uint256 first = market.claim(ROUND);
        assertGt(first, 0);
        vm.prank(alice);
        assertEq(market.claim(ROUND), 0, "second claim pays nothing");
    }

    // ------------------------------------------------------------------
    // LP lifecycle: remove, fees
    // ------------------------------------------------------------------

    function test_removeLiquidityProRata() public {
        uint256 shares = _seedPool(TIER_LOW, LIQ);
        (uint256 rY, uint256 rN) = _reserves(ROUND, TIER_LOW);
        uint256 total = _totalShares(ROUND, TIER_LOW);

        vm.prank(lpAda);
        (uint256 yesOut, uint256 noOut,) = market.removeLiquidity(ROUND, TIER_LOW, shares / 2, 0, 0, NO_DEADLINE);

        assertEq(yesOut, rY * (shares / 2) / total);
        assertEq(noOut, rN * (shares / 2) / total);
        assertEq(_yesBal(lpAda), yesOut);
        assertEq(_noBal(lpAda), noOut);
    }

    function test_removeLiquidityGuards() public {
        uint256 shares = _seedPool(TIER_LOW, LIQ);
        vm.startPrank(lpAda);
        vm.expectRevert(GestureSeriesMarket.InsufficientShares.selector);
        market.removeLiquidity(ROUND, TIER_LOW, shares + 1, 0, 0, NO_DEADLINE);
        vm.expectRevert(GestureSeriesMarket.InsufficientShares.selector);
        market.removeLiquidity(ROUND, TIER_LOW, 0, 0, 0, NO_DEADLINE);
        vm.expectRevert(GestureSeriesMarket.DeadlineExpired.selector);
        market.removeLiquidity(ROUND, TIER_LOW, shares, 0, 0, block.timestamp - 1);
        vm.expectRevert(GestureSeriesMarket.Slippage.selector);
        market.removeLiquidity(ROUND, TIER_LOW, shares, type(uint256).max, 0, NO_DEADLINE);
        vm.stopPrank();
        // Non-LP has nothing to remove.
        vm.prank(alice);
        vm.expectRevert(GestureSeriesMarket.InsufficientShares.selector);
        market.removeLiquidity(ROUND, TIER_LOW, 1, 0, 0, NO_DEADLINE);
    }

    function test_removeLiquidityAfterResolutionAndClaim() public {
        uint256 shares = _seedPool(TIER_LOW, LIQ);
        vm.prank(alice);
        market.betYes(ROUND, TIER_LOW, 3_000e18, 0, NO_DEADLINE);

        _endRoundWith(THRESHOLD + 10);
        market.resolve(ROUND);

        vm.startPrank(lpAda);
        (uint256 yesOut, uint256 noOut, uint256 fees) =
            market.removeLiquidity(ROUND, TIER_LOW, shares, 0, 0, NO_DEADLINE);
        uint256 claimed = market.claim(ROUND);
        vm.stopPrank();

        assertGt(fees, 0, "LP earned the bet fee");
        assertEq(claimed, yesOut, "post-resolution the YES side pays 1:1");
        assertGt(noOut, 0, "the losing side came out too (worth 0)");
    }

    function test_feesAccrueToLpsProRataAndExactly() public {
        _seedPool(TIER_LOW, LIQ); // Ada: LIQ - DEAD_SHARES shares
        vm.prank(lpBen);
        market.addLiquidity(ROUND, TIER_LOW, LIQ / 2, 0, 0, NO_DEADLINE); // Ben: LIQ/2 shares

        vm.prank(alice);
        market.betYes(ROUND, TIER_LOW, 9_000e18, 0, NO_DEADLINE);
        uint256 fee = 9_000e18 * TIER_LOW / BPS;
        assertEq(_feeReserve(ROUND, TIER_LOW), fee, "whole fee escrowed");

        (, uint256 adaPending) = market.lpPositionOf(ROUND, TIER_LOW, lpAda);
        (, uint256 benPending) = market.lpPositionOf(ROUND, TIER_LOW, lpBen);
        // Ada holds (LIQ - dead) shares, Ben LIQ/2, dead shares eat a sliver.
        assertApproxEqAbs(adaPending, fee * 2 / 3, 1e6, "Ada earns ~2/3");
        assertApproxEqAbs(benPending, fee / 3, 1e6, "Ben earns ~1/3");
        assertLe(adaPending + benPending, fee, "cannot claim more than escrowed");

        uint256 adaBefore = cst.balanceOf(lpAda);
        vm.prank(lpAda);
        assertEq(market.claimFees(ROUND, TIER_LOW), adaPending);
        assertEq(cst.balanceOf(lpAda) - adaBefore, adaPending);
        (, uint256 adaAfter) = market.lpPositionOf(ROUND, TIER_LOW, lpAda);
        assertEq(adaAfter, 0, "pending resets after claim");

        vm.prank(lpBen);
        market.claimFees(ROUND, TIER_LOW);
        assertLe(_feeReserve(ROUND, TIER_LOW), fee - adaPending - benPending + 2, "only dust left in escrow");
    }

    function test_lateJoinerEarnsNoFeesFromEarlierBets() public {
        _seedPool(TIER_LOW, LIQ);
        vm.prank(alice);
        market.betYes(ROUND, TIER_LOW, 5_000e18, 0, NO_DEADLINE); // fee #1: Ada only

        vm.prank(lpBen);
        market.addLiquidity(ROUND, TIER_LOW, LIQ, 0, 0, NO_DEADLINE);
        (, uint256 benPendingAfterJoin) = market.lpPositionOf(ROUND, TIER_LOW, lpBen);
        assertEq(benPendingAfterJoin, 0, "no retroactive fees for late joiners");

        vm.prank(bob);
        market.betNo(ROUND, TIER_LOW, 5_000e18, 0, NO_DEADLINE); // fee #2: split
        (, uint256 benPending) = market.lpPositionOf(ROUND, TIER_LOW, lpBen);
        assertGt(benPending, 0, "late joiner earns from later bets");
    }

    function test_claimFeesOnEmptyPositionIsZero() public {
        _seedPool(TIER_LOW, LIQ);
        vm.prank(carol);
        assertEq(market.claimFees(ROUND, TIER_LOW), 0);
    }

    // ------------------------------------------------------------------
    // Full lifecycle & multi-round
    // ------------------------------------------------------------------

    function test_fullLifecycleConservesCstToDust() public {
        _seedAllPools(LIQ);
        vm.prank(lpBen);
        market.addLiquidity(ROUND, TIER_MID, 4_000e18, 0, 0, NO_DEADLINE);

        vm.prank(alice);
        market.betYesBest(ROUND, 6_000e18, 0, NO_DEADLINE);
        vm.prank(bob);
        market.betNo(ROUND, TIER_HIGH, 3_000e18, 0, NO_DEADLINE);
        vm.startPrank(carol);
        market.mintSets(ROUND, 1_000e18);
        market.redeemSets(ROUND, 400e18);
        vm.stopPrank();

        _endRoundWith(THRESHOLD + 42);
        market.resolve(ROUND);

        // Everyone exits everything.
        address[5] memory everyone = [lpAda, lpBen, alice, bob, carol];
        uint16[3] memory tiers = [TIER_LOW, TIER_MID, TIER_HIGH];
        for (uint256 i = 0; i < everyone.length; i++) {
            for (uint256 t = 0; t < tiers.length; t++) {
                (uint256 shares,) = market.lpPositionOf(ROUND, tiers[t], everyone[i]);
                if (shares > 0) {
                    vm.prank(everyone[i]);
                    market.removeLiquidity(ROUND, tiers[t], shares, 0, 0, NO_DEADLINE);
                }
                vm.prank(everyone[i]);
                market.claimFees(ROUND, tiers[t]);
            }
            vm.prank(everyone[i]);
            market.claim(ROUND);
        }

        // Only dead-share reserves and rounding dust may remain.
        assertLt(cst.balanceOf(address(market)), 1e6, "more than dust stuck after full drain");
    }

    function test_consecutiveRoundsRunIndependently() public {
        _seedPool(TIER_LOW, LIQ);
        vm.prank(alice);
        market.betYes(ROUND, TIER_LOW, 1_000e18, 0, NO_DEADLINE);

        // Round ends at 950 (> 800): YES wins round 5; round 6's threshold is 950.
        _endRoundWith(950);
        market.resolve(ROUND);

        vm.prank(lpBen);
        market.addLiquidity(ROUND + 1, TIER_LOW, LIQ, 5_000, 0, NO_DEADLINE);
        (,,, uint256 threshold,,,) = market.roundState(ROUND + 1);
        assertEq(threshold, 950, "next round compares against the new count");

        vm.prank(bob);
        market.betNo(ROUND + 1, TIER_LOW, 500e18, 0, NO_DEADLINE);
        (uint256 rY,) = _reserves(ROUND, TIER_LOW);
        (uint256 rY6,) = _reserves(ROUND + 1, TIER_LOW);
        assertGt(rY6, 0);
        assertGt(rY, 0, "old round's pool untouched by new round's trading");

        // Old round claims still work while the new round trades.
        vm.prank(alice);
        assertGt(market.claim(ROUND), 0);
    }

    function test_roundStateViewCoherent() public {
        (bool initialized,,,,, bool active,) = market.roundState(ROUND);
        assertFalse(initialized);
        assertTrue(active);

        _seedPool(TIER_LOW, LIQ);
        game.setNumBids(ROUND, 500);
        (,,, uint256 threshold, uint256 count,, bool decided) = market.roundState(ROUND);
        assertEq(threshold, THRESHOLD);
        assertEq(count, 500);
        assertFalse(decided);

        _crossThreshold();
        (,,,,,, decided) = market.roundState(ROUND);
        assertTrue(decided);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GestureMarket} from "../src/GestureMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";
import {MarketTestBase} from "./utils/MarketTestBase.sol";

/// @notice Core unit tests: happy paths, guards, and known edge cases.
contract GestureMarketTest is MarketTestBase {
    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    function test_constructorState() public view {
        assertEq(market.round(), ROUND);
        assertEq(address(market.cst()), address(cst));
        assertEq(market.creator(), creator);
        assertEq(market.reserveHigher(), LIQ);
        assertEq(market.reserveLower(), LIQ);
        assertEq(cst.balanceOf(address(market)), LIQ);
        assertEq(cst.balanceOf(creator), 0);
        // Equal reserves -> midpoint prediction.
        assertEq(market.predictedCount(), (MIN + MAX) / 2);
    }

    function test_constructorRejectsBadParams() public {
        cst.mint(creator, LIQ * 4);

        // Empty or inverted range.
        vm.expectRevert(GestureMarket.InvalidParams.selector);
        vm.prank(creator);
        new GestureMarket(ICosmicSignatureGame(address(game)), MAX, MAX, FEE_BPS, LIQ);

        // Range upper bound above the hard COUNT_LIMIT (1e12).
        vm.expectRevert(GestureMarket.InvalidParams.selector);
        vm.prank(creator);
        new GestureMarket(ICosmicSignatureGame(address(game)), 0, 1e12 + 1, FEE_BPS, LIQ);

        // Fee above 10%.
        vm.expectRevert(GestureMarket.InvalidParams.selector);
        vm.prank(creator);
        new GestureMarket(ICosmicSignatureGame(address(game)), MIN, MAX, 1_001, LIQ);

        // No liquidity.
        vm.expectRevert(GestureMarket.InvalidParams.selector);
        vm.prank(creator);
        new GestureMarket(ICosmicSignatureGame(address(game)), MIN, MAX, FEE_BPS, 0);
    }

    function test_constructorAcceptsBoundaryParams() public {
        // maxCount exactly at COUNT_LIMIT, fee exactly at cap, 1 wei liquidity.
        GestureMarket m = _deployMarket(0, 1e12, 1_000, 1);
        assertEq(m.maxCount(), 1e12);
        assertEq(m.feeBps(), 1_000);
    }

    // ------------------------------------------------------------------
    // Trading
    // ------------------------------------------------------------------

    function test_betHigherMovesPredictionUp() public {
        uint256 before = market.predictedCount();

        vm.prank(alice);
        uint256 tokensOut = market.betHigher(5_000e18, 0);

        assertGt(market.predictedCount(), before, "prediction should rise");
        // Buying below max price always yields more tokens than CST spent (net of fee).
        assertGt(tokensOut, 5_000e18 - 5_000e18 * FEE_BPS / 10_000);
        assertEq(market.higherBalance(alice), tokensOut);
        assertEq(market.lowerBalance(alice), 0);
    }

    function test_betLowerMovesPredictionDown() public {
        uint256 before = market.predictedCount();

        vm.prank(bob);
        uint256 tokensOut = market.betLower(5_000e18, 0);

        assertLt(market.predictedCount(), before, "prediction should fall");
        assertEq(market.lowerBalance(bob), tokensOut);
        assertEq(market.higherBalance(bob), 0);
    }

    function test_quotesMatchActualBets() public {
        uint256 quotedHigher = market.quoteBetHigher(1_234e18);
        vm.prank(alice);
        assertEq(market.betHigher(1_234e18, 0), quotedHigher);

        uint256 quotedLower = market.quoteBetLower(777e18);
        vm.prank(bob);
        assertEq(market.betLower(777e18, 0), quotedLower);
    }

    function test_slippageGuard() public {
        uint256 quoted = market.quoteBetHigher(1_000e18);
        vm.expectRevert(GestureMarket.Slippage.selector);
        vm.prank(alice);
        market.betHigher(1_000e18, quoted + 1);
    }

    function test_poolInvariantNeverDecreases() public {
        uint256 kBefore = market.reserveHigher() * market.reserveLower();
        vm.prank(alice);
        market.betHigher(3_333e18, 0);
        uint256 kAfter = market.reserveHigher() * market.reserveLower();
        assertGe(kAfter, kBefore, "k must not decrease");
    }

    function test_mintRedeemSetsRoundtrip() public {
        uint256 balanceBefore = cst.balanceOf(alice);

        vm.startPrank(alice);
        market.mintSets(100e18);
        assertEq(market.higherBalance(alice), 100e18);
        assertEq(market.lowerBalance(alice), 100e18);

        market.redeemSets(100e18);
        vm.stopPrank();

        assertEq(market.higherBalance(alice), 0);
        assertEq(market.lowerBalance(alice), 0);
        assertEq(cst.balanceOf(alice), balanceBefore, "sets roundtrip is free");
    }

    function test_exitBetEarlyViaOppositeSidePlusRedeem() public {
        vm.startPrank(alice);
        uint256 higherOut = market.betHigher(1_000e18, 0);
        // Change of mind: buy LOWER, pair up, redeem for CST.
        uint256 lowerOut = market.betLower(1_000e18, 0);
        uint256 pairs = higherOut < lowerOut ? higherOut : lowerOut;
        market.redeemSets(pairs);
        vm.stopPrank();

        assertEq(market.higherBalance(alice), higherOut - pairs);
        assertEq(market.lowerBalance(alice), lowerOut - pairs);
    }

    function test_tradingClosedOnceRoundEnds() public {
        vm.prank(alice);
        market.mintSets(10e18);

        _endRoundWith(700);

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

    // ------------------------------------------------------------------
    // Resolution & claims
    // ------------------------------------------------------------------

    function test_resolveRevertsWhileRoundActive() public {
        vm.expectRevert(GestureMarket.NotResolvable.selector);
        market.resolve();
    }

    function test_resolveOnlyOnce() public {
        _endRoundWith(700);
        market.resolve();
        vm.expectRevert(GestureMarket.AlreadyResolved.selector);
        market.resolve();
    }

    function test_claimBeforeResolveReverts() public {
        vm.expectRevert(GestureMarket.NotResolved.selector);
        vm.prank(alice);
        market.claim();
    }

    function test_fullFlowResolveAndClaim() public {
        // Bets sized reasonably against 10k liquidity; oversized bets suffer so
        // much slippage that even a directionally right bet can lose.
        vm.prank(alice);
        uint256 aliceHigher = market.betHigher(5_000e18, 0);
        vm.prank(bob);
        uint256 bobLower = market.betLower(2_000e18, 0);

        // Final count 1000 -> f = (1000 - 200) / (1200 - 200) = 0.8.
        _endRoundWith(1_000);
        market.resolve();

        assertTrue(market.resolved());
        assertEq(market.finalGestureCount(), 1_000);
        assertEq(market.payoutPerHigher(), 0.8e18);
        assertEq(market.predictedCount(), 1_000, "post-resolution prediction is the outcome");

        // Fees went straight to the creator at resolution.
        uint256 expectedFees = (5_000e18 + 2_000e18) * FEE_BPS / 10_000;
        assertEq(cst.balanceOf(creator), expectedFees);

        uint256 aliceBefore = cst.balanceOf(alice);
        vm.prank(alice);
        uint256 alicePayout = market.claim();
        assertEq(alicePayout, aliceHigher * 0.8e18 / 1e18);
        assertEq(cst.balanceOf(alice) - aliceBefore, alicePayout);
        assertEq(market.higherBalance(alice), 0, "balance zeroed after claim");

        vm.prank(bob);
        uint256 bobPayout = market.claim();
        assertEq(bobPayout, bobLower * 0.2e18 / 1e18);

        // Alice bet the right direction and profited; bob lost.
        assertGt(alicePayout, 5_000e18);
        assertLt(bobPayout, 2_000e18);

        // Creator claims the pool's remaining tokens.
        vm.prank(creator);
        uint256 creatorPayout = market.claim();
        assertGt(creatorPayout, 0);

        // Everything is paid out except integer-division dust.
        assertLt(cst.balanceOf(address(market)), 4, "only dust remains");
    }

    function test_resolveClampsAboveMax() public {
        vm.prank(alice);
        market.betHigher(1_000e18, 0);

        _endRoundWith(50_000); // way above MAX
        market.resolve();

        assertEq(market.payoutPerHigher(), 1e18, "HIGHER pays full");
        assertEq(market.predictedCount(), MAX);

        uint256 tokens = market.higherBalance(alice);
        vm.prank(alice);
        assertEq(market.claim(), tokens, "each HIGHER token pays exactly 1 CST");
    }

    function test_resolveClampsBelowMin() public {
        vm.prank(alice);
        uint256 tokensOut = market.betHigher(1_000e18, 0);
        assertGt(tokensOut, 0);

        _endRoundWith(10); // below MIN
        market.resolve();

        assertEq(market.payoutPerHigher(), 0, "HIGHER pays nothing");

        vm.prank(alice);
        assertEq(market.claim(), 0);
    }

    function test_resolveAtExactBoundaries() public {
        uint256 snap = vm.snapshotState();

        _endRoundWith(MIN);
        market.resolve();
        assertEq(market.payoutPerHigher(), 0, "count == minCount pays LOWER fully");

        vm.revertToState(snap);
        _endRoundWith(MAX);
        market.resolve();
        assertEq(market.payoutPerHigher(), 1e18, "count == maxCount pays HIGHER fully");
    }

    function test_resolveWithNoBetsRefundsCreatorExactly() public {
        _endRoundWith(700);
        market.resolve();

        vm.prank(creator);
        uint256 payout = market.claim();
        assertEq(payout, LIQ, "creator gets full liquidity back");
        assertEq(cst.balanceOf(address(market)), 0);
    }

    function test_claimIsIdempotent() public {
        vm.prank(alice);
        market.betHigher(1_000e18, 0);
        _endRoundWith(900);
        market.resolve();

        vm.prank(alice);
        uint256 first = market.claim();
        assertGt(first, 0);

        vm.prank(alice);
        assertEq(market.claim(), 0, "second claim pays nothing");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GestureSeriesMarket} from "../src/GestureSeriesMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";
import {SeriesTestBase} from "./utils/SeriesTestBase.sol";

/// @dev Exposes the internal AMM math for direct property fuzzing.
contract SeriesHarness is GestureSeriesMarket {
    constructor(ICosmicSignatureGame game_, uint16[] memory tiers) GestureSeriesMarket(game_, tiers) {}

    function exposedBuyAmount(uint256 reserveOut, uint256 reserveIn, uint256 net) external pure returns (uint256) {
        return _buyAmount(reserveOut, reserveIn, net);
    }
}

/// @notice Property-based fuzz tests. Every test states an economic or safety
/// property that must hold for ALL inputs, not just hand-picked examples.
/// Run long campaigns with: FOUNDRY_PROFILE=heavy forge test
contract GestureSeriesMarketFuzzTest is SeriesTestBase {
    SeriesHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new SeriesHarness(ICosmicSignatureGame(address(game)), _defaultTiers());
    }

    // ------------------------------------------------------------------
    // Pure AMM math
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

    function testFuzz_constructorAcceptsAnyValidTiers(uint256 seed, uint256 count) public {
        count = bound(count, 1, 5);
        uint16[] memory tiers = new uint16[](count);
        uint16 prev = 0;
        for (uint256 i = 0; i < count; i++) {
            // Strictly ascending picks in (prev, 1000], leaving room for the rest.
            uint16 maxHere = uint16(1_000 - (count - 1 - i));
            uint16 tier = uint16(bound(uint256(keccak256(abi.encode(seed, i))), prev + 1, maxHere));
            tiers[i] = tier;
            prev = tier;
        }
        GestureSeriesMarket m = new GestureSeriesMarket(ICosmicSignatureGame(address(game)), tiers);
        assertEq(m.feeTiers().length, count);
    }

    function testFuzz_constructorRejectsNonAscendingTiers(uint256 a, uint256 b) public {
        uint16 first = uint16(bound(a, 1, 1_000));
        uint16 second = uint16(bound(b, 0, first)); // <= first (or zero): never valid
        uint16[] memory tiers = new uint16[](2);
        tiers[0] = first;
        tiers[1] = second;
        vm.expectRevert(GestureSeriesMarket.InvalidParams.selector);
        new GestureSeriesMarket(ICosmicSignatureGame(address(game)), tiers);
    }

    // ------------------------------------------------------------------
    // Opening and joining pools
    // ------------------------------------------------------------------

    /// Opening a pool at any probability conserves tokens exactly (reserves +
    /// excess = deposit on both sides), prices the pool at the requested
    /// probability, and mints deposit-minus-dead shares.
    function testFuzz_openPoolAtAnyProbability(uint256 liq, uint256 prob) public {
        liq = bound(liq, 1e15, 1e24);
        prob = bound(prob, 100, 9_900);

        vm.prank(lpAda);
        uint256 shares = market.addLiquidity(ROUND, TIER_LOW, liq, prob, 0, NO_DEADLINE);

        (uint256 rY, uint256 rN) = _reserves(ROUND, TIER_LOW);
        (uint256 yes, uint256 no) = market.balancesOf(ROUND, lpAda);
        assertEq(rY + yes, liq, "YES tokens conserved");
        assertEq(rN + no, liq, "NO tokens conserved");
        assertEq(shares, liq - DEAD_SHARES, "shares = deposit minus dead shares");
        assertEq(_totalShares(ROUND, TIER_LOW), liq);
        // Implied probability within 1 bps of the request (integer rounding).
        assertApproxEqAbs(_probBps(ROUND, TIER_LOW), prob, 1, "opening odds off");
    }

    /// Joining at any pool state never moves the price, conserves tokens, and
    /// the joiner's instantly-claimable cut can never exceed what they put in
    /// (rounding favors incumbent LPs).
    function testFuzz_joinPoolIsFairFromAnyState(uint256 liq, uint256 prob, uint256 skew, bool skewYes, uint256 add)
        public
    {
        liq = bound(liq, 1e15, 1e24);
        prob = bound(prob, 100, 9_900);
        skew = bound(skew, 1, 1e23);
        add = bound(add, 1, 1e24);

        vm.prank(lpAda);
        market.addLiquidity(ROUND, TIER_LOW, liq, prob, 0, NO_DEADLINE);
        vm.prank(alice);
        if (skewYes) market.betYes(ROUND, TIER_LOW, skew, 0, NO_DEADLINE);
        else market.betNo(ROUND, TIER_LOW, skew, 0, NO_DEADLINE);

        (uint256 rY, uint256 rN) = _reserves(ROUND, TIER_LOW);
        uint256 m = rY > rN ? rY : rN;
        uint256 probBefore = _probBps(ROUND, TIER_LOW);
        uint256 totalBefore = _totalShares(ROUND, TIER_LOW);

        vm.prank(lpBen);
        try market.addLiquidity(ROUND, TIER_LOW, add, 0, 0, NO_DEADLINE) returns (uint256 shares) {
            assertGt(shares, 0);
            assertApproxEqAbs(_probBps(ROUND, TIER_LOW), probBefore, 1, "join moved the price");

            (uint256 rY2, uint256 rN2) = _reserves(ROUND, TIER_LOW);
            (uint256 yes, uint256 no) = market.balancesOf(ROUND, lpBen);
            assertEq(rY2 - rY + yes, add, "YES tokens conserved on join");
            assertEq(rN2 - rN + no, add, "NO tokens conserved on join");

            uint256 total2 = _totalShares(ROUND, TIER_LOW);
            assertEq(total2, totalBefore + shares);
            // Pro-rata claim right after joining <= what was deposited into the pool.
            assertLe(rY2 * shares / total2, rY2 - rY, "joiner could extract YES from incumbents");
            assertLe(rN2 * shares / total2, rN2 - rN, "joiner could extract NO from incumbents");
        } catch (bytes memory reason) {
            // Only acceptable rejection: a deposit too small to mint one share.
            assertEq(reason, abi.encodePacked(GestureSeriesMarket.InsufficientLiquidity.selector));
            assertLt(totalBefore * add, m, "sizable deposit rejected");
        }
    }

    /// Add-then-remove immediately can never pay out more CST-equivalent value
    /// than went in, for any pool state (no free-mint pump).
    function testFuzz_addRemoveRoundtripNeverProfits(uint256 skew, bool skewYes, uint256 add) public {
        skew = bound(skew, 1, 1e23);
        add = bound(add, 1e6, 1e24);
        _seedPool(TIER_LOW, LIQ);
        vm.prank(alice);
        if (skewYes) market.betYes(ROUND, TIER_LOW, skew, 0, NO_DEADLINE);
        else market.betNo(ROUND, TIER_LOW, skew, 0, NO_DEADLINE);

        uint256 cstBefore = cst.balanceOf(lpBen);
        vm.startPrank(lpBen);
        uint256 shares = market.addLiquidity(ROUND, TIER_LOW, add, 0, 0, NO_DEADLINE);
        market.removeLiquidity(ROUND, TIER_LOW, shares, 0, 0, NO_DEADLINE);
        (uint256 yes, uint256 no) = market.balancesOf(ROUND, lpBen);
        market.redeemSets(ROUND, yes < no ? yes : no);
        vm.stopPrank();

        // Even valuing the leftover one-sided tokens at a full 1 CST each
        // (their ceiling), the roundtrip can never come out ahead.
        (uint256 yesLeft, uint256 noLeft) = market.balancesOf(ROUND, lpBen);
        uint256 residualCeiling = yesLeft > noLeft ? yesLeft : noLeft;
        assertLe(cst.balanceOf(lpBen) + residualCeiling, cstBefore, "add/remove roundtrip minted value");
    }

    // ------------------------------------------------------------------
    // Betting properties
    // ------------------------------------------------------------------

    /// Quotes must exactly equal executed bets, from any skewed pool state,
    /// on every tier.
    function testFuzz_quotesMatchBetsFromAnyState(uint256 skew, bool skewYes, uint256 amount, uint256 tierSeed) public {
        uint16 tier = _tierAt(tierSeed);
        skew = bound(skew, 1, 1e23);
        amount = bound(amount, 1, 1e23);
        _seedAllPools(LIQ);

        vm.prank(bob);
        if (skewYes) market.betYes(ROUND, tier, skew, 0, NO_DEADLINE);
        else market.betNo(ROUND, tier, skew, 0, NO_DEADLINE);

        uint256 quotedYes = market.quoteBetYes(ROUND, tier, amount);
        uint256 quotedNo = market.quoteBetNo(ROUND, tier, amount);

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        assertEq(market.betYes(ROUND, tier, amount, 0, NO_DEADLINE), quotedYes, "YES quote mismatch");
        vm.revertToState(snap);
        vm.prank(alice);
        assertEq(market.betNo(ROUND, tier, amount, 0, NO_DEADLINE), quotedNo, "NO quote mismatch");
    }

    /// After ANY sequence of bets on one pool: the probability stays in
    /// (0, 10000), k never decreases, reserves never empty, and every bet
    /// pays at least its net input in tokens.
    function testFuzz_arbitraryBetSequenceKeepsPoolHealthy(uint256[4] memory amounts, uint8 dirMask) public {
        _seedPool(TIER_MID, LIQ);
        (uint256 rY, uint256 rN) = _reserves(ROUND, TIER_MID);
        uint256 kBefore = rY * rN;

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = bound(amounts[i], 1, 250_000e18);
            vm.prank(alice);
            uint256 tokensOut = (dirMask >> i) & 1 == 1
                ? market.betYes(ROUND, TIER_MID, amount, 0, NO_DEADLINE)
                : market.betNo(ROUND, TIER_MID, amount, 0, NO_DEADLINE);
            assertGe(tokensOut, amount - amount * uint256(TIER_MID) / BPS, "token cost above 1 CST");

            (rY, rN) = _reserves(ROUND, TIER_MID);
            assertGe(rY, 1, "YES reserve emptied");
            assertGe(rN, 1, "NO reserve emptied");
            uint256 prob = _probBps(ROUND, TIER_MID);
            assertGt(prob, 0, "probability pinned to 0");
            assertLt(prob, BPS, "probability pinned to 1");
            assertGe(rY * rN, kBefore, "k decreased");
            kBefore = rY * rN;
        }
    }

    /// A bet split into two parts must give (near) identical tokens as one
    /// bet: path independence up to integer rounding.
    function testFuzz_splitBetEquivalentToSingleBet(uint256 a, uint256 b) public {
        a = bound(a, 1e18, 100_000e18);
        b = bound(b, 1e18, 100_000e18);
        _seedPool(TIER_LOW, LIQ);

        uint256 snap = vm.snapshotState();
        vm.startPrank(alice);
        uint256 split =
            market.betYes(ROUND, TIER_LOW, a, 0, NO_DEADLINE) + market.betYes(ROUND, TIER_LOW, b, 0, NO_DEADLINE);
        vm.stopPrank();

        vm.revertToState(snap);
        vm.prank(alice);
        uint256 single = market.betYes(ROUND, TIER_LOW, a + b, 0, NO_DEADLINE);

        assertApproxEqAbs(split, single, 4, "path dependence beyond rounding");
    }

    /// Any minTokensOut above the true output must revert — the guard that
    /// defeats liquidity-pull and sandwich games.
    function testFuzz_slippageGuardAlwaysEnforced(uint256 amount, uint256 excess) public {
        amount = bound(amount, 1, 500_000e18);
        excess = bound(excess, 1, type(uint128).max);
        _seedPool(TIER_HIGH, LIQ);
        uint256 quoted = market.quoteBetYes(ROUND, TIER_HIGH, amount);

        vm.expectRevert(GestureSeriesMarket.Slippage.selector);
        vm.prank(alice);
        market.betYes(ROUND, TIER_HIGH, amount, quoted + excess, NO_DEADLINE);
    }

    /// No money pump: betting both sides and redeeming pairs pre-resolution
    /// can never withdraw more CST than went in, against any skewed pool.
    function testFuzz_noProfitExtractionPreResolution(uint256 skew, bool skewYes, uint256 a, uint256 b) public {
        skew = bound(skew, 1, 500_000e18);
        a = bound(a, 1, 400_000e18);
        b = bound(b, 1, 400_000e18);
        _seedPool(TIER_LOW, LIQ);

        vm.prank(bob);
        if (skewYes) market.betYes(ROUND, TIER_LOW, skew, 0, NO_DEADLINE);
        else market.betNo(ROUND, TIER_LOW, skew, 0, NO_DEADLINE);

        uint256 aliceStart = cst.balanceOf(alice);
        vm.startPrank(alice);
        market.betYes(ROUND, TIER_LOW, a, 0, NO_DEADLINE);
        market.betNo(ROUND, TIER_LOW, b, 0, NO_DEADLINE);
        (uint256 yes, uint256 no) = market.balancesOf(ROUND, alice);
        market.redeemSets(ROUND, yes < no ? yes : no);
        vm.stopPrank();

        assertLe(cst.balanceOf(alice), aliceStart, "pre-resolution profit extraction");
    }

    /// Cross-tier routing: the best-tier bet is at least as good as betting
    /// the same amount on ANY single tier, for any pool configuration.
    function testFuzz_bestTierRoutingIsOptimal(
        uint256[3] memory liqs,
        uint256[3] memory skews,
        uint8 dirMask,
        uint256 amount,
        bool yes
    ) public {
        amount = bound(amount, 1, 1e23);
        uint16[3] memory tiers = [TIER_LOW, TIER_MID, TIER_HIGH];
        for (uint256 i = 0; i < 3; i++) {
            uint256 liq = bound(liqs[i], 1e15, 1e23);
            vm.prank(lpAda);
            market.addLiquidity(ROUND, tiers[i], liq, 5_000, 0, NO_DEADLINE);
            uint256 skew = bound(skews[i], 1, 1e22);
            vm.prank(bob);
            if ((dirMask >> i) & 1 == 1) market.betYes(ROUND, tiers[i], skew, 0, NO_DEADLINE);
            else market.betNo(ROUND, tiers[i], skew, 0, NO_DEADLINE);
        }

        (, uint256 bestQuote) = yes ? market.quoteBetYesBest(ROUND, amount) : market.quoteBetNoBest(ROUND, amount);
        for (uint256 i = 0; i < 3; i++) {
            uint256 single =
                yes ? market.quoteBetYes(ROUND, tiers[i], amount) : market.quoteBetNo(ROUND, tiers[i], amount);
            assertGe(bestQuote, single, "router missed a better tier");
        }

        vm.prank(alice);
        (, uint256 executed) =
            yes ? market.betYesBest(ROUND, amount, 0, NO_DEADLINE) : market.betNoBest(ROUND, amount, 0, NO_DEADLINE);
        assertEq(executed, bestQuote, "best-tier execution must match its quote");
    }

    // ------------------------------------------------------------------
    // Fees
    // ------------------------------------------------------------------

    /// Fee escrow is exact to the wei: after any bets, feeReserve equals the
    /// per-bet floor formula sum; all LP claims together never exceed it and
    /// leave at most share-rounding dust.
    function testFuzz_feeAccountingExactAndConserved(uint256[3] memory amounts, uint8 dirMask, uint256 benLiq) public {
        _seedPool(TIER_MID, LIQ);
        benLiq = bound(benLiq, 1e15, 1e23);
        vm.prank(lpBen);
        market.addLiquidity(ROUND, TIER_MID, benLiq, 0, 0, NO_DEADLINE);

        uint256 expectedFees;
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = bound(amounts[i], 1, 200_000e18);
            vm.prank(alice);
            if ((dirMask >> i) & 1 == 1) market.betYes(ROUND, TIER_MID, amount, 0, NO_DEADLINE);
            else market.betNo(ROUND, TIER_MID, amount, 0, NO_DEADLINE);
            expectedFees += amount * uint256(TIER_MID) / BPS;
        }
        assertEq(_feeReserve(ROUND, TIER_MID), expectedFees, "fee escrow mismatch");

        (, uint256 adaPending) = market.lpPositionOf(ROUND, TIER_MID, lpAda);
        (, uint256 benPending) = market.lpPositionOf(ROUND, TIER_MID, lpBen);
        assertLe(adaPending + benPending, expectedFees, "LPs owed more than escrowed");

        vm.prank(lpAda);
        uint256 adaGot = market.claimFees(ROUND, TIER_MID);
        vm.prank(lpBen);
        uint256 benGot = market.claimFees(ROUND, TIER_MID);
        assertEq(adaGot, adaPending);
        assertEq(benGot, benPending);
        // Residual = dead-share cut + per-bet accumulator rounding: dust only.
        assertEq(_feeReserve(ROUND, TIER_MID), expectedFees - adaGot - benGot, "escrow accounting broken");
        assertLt(_feeReserve(ROUND, TIER_MID), 1e6, "excess fee dust");
    }

    /// Fees are proportional to shares: an LP with twice the shares accrues
    /// twice the fees from the same bets (exact up to 1 wei per bet).
    function testFuzz_feesProRataToShares(uint256 amount) public {
        amount = bound(amount, 1e6, 200_000e18);
        _seedPool(TIER_LOW, LIQ); // Ada: LIQ - dead
        vm.prank(lpBen);
        market.addLiquidity(ROUND, TIER_LOW, LIQ / 2, 0, 0, NO_DEADLINE); // Ben: LIQ/2

        vm.prank(alice);
        market.betYes(ROUND, TIER_LOW, amount, 0, NO_DEADLINE);

        (uint256 adaShares, uint256 adaPending) = market.lpPositionOf(ROUND, TIER_LOW, lpAda);
        (uint256 benShares, uint256 benPending) = market.lpPositionOf(ROUND, TIER_LOW, lpBen);
        // adaPending/adaShares == benPending/benShares within rounding.
        assertApproxEqAbs(
            adaPending * 1e18 / adaShares, benPending * 1e18 / benShares, 1e6, "per-share fee rate differs between LPs"
        );
    }

    // ------------------------------------------------------------------
    // Lifecycle & resolution
    // ------------------------------------------------------------------

    /// Resolution truth table, for any counts: after the round ends YES wins
    /// iff final > threshold (ties pay NO); early resolution exists iff the
    /// live count already exceeds the threshold, and always resolves YES.
    function testFuzz_resolutionMatchesStrictComparison(uint256 threshold, uint256 finalCount, bool early) public {
        threshold = bound(threshold, 0, 1e30);
        finalCount = bound(finalCount, 0, 1e30);
        game.setNumBids(ROUND - 1, threshold);
        _seedPool(TIER_LOW, LIQ);

        if (early) {
            game.setNumBids(ROUND, finalCount); // round stays live
            if (finalCount > threshold) {
                market.resolve(ROUND);
                (, bool resolved, bool yesWon,,,,) = market.roundState(ROUND);
                assertTrue(resolved);
                assertTrue(yesWon, "early resolution can only be YES");
            } else {
                vm.expectRevert(GestureSeriesMarket.NotResolvable.selector);
                market.resolve(ROUND);
            }
        } else {
            _endRoundWith(finalCount);
            market.resolve(ROUND);
            (,, bool yesWon,,,,) = market.roundState(ROUND);
            assertEq(yesWon, finalCount > threshold, "strict comparison violated");
        }
    }

    /// Once the live count crosses the threshold, every bet and liquidity add
    /// reverts — there is no block in which a decided outcome can be traded.
    function testFuzz_noTradingOnDecidedOutcome(uint256 count) public {
        _seedPool(TIER_LOW, LIQ);
        count = bound(count, THRESHOLD + 1, 1e30);
        game.setNumBids(ROUND, count);

        vm.startPrank(alice);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.betYes(ROUND, TIER_LOW, 1e18, 0, NO_DEADLINE);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.betNoBest(ROUND, 1e18, 0, NO_DEADLINE);
        vm.stopPrank();
        vm.prank(lpBen);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.addLiquidity(ROUND, TIER_LOW, 1e18, 0, 0, NO_DEADLINE);
    }

    /// Winning tokens always pay exactly 1 CST each, losing exactly 0, no
    /// matter how the position was assembled.
    function testFuzz_claimPaysExactlyOneCstPerWinningToken(uint256 a, uint256 b, uint256 mintAmt, bool yesWins)
        public
    {
        a = bound(a, 1, 300_000e18);
        b = bound(b, 1, 300_000e18);
        mintAmt = bound(mintAmt, 1, 100_000e18);
        _seedPool(TIER_MID, LIQ);

        vm.startPrank(alice);
        market.betYes(ROUND, TIER_MID, a, 0, NO_DEADLINE);
        market.betNo(ROUND, TIER_MID, b, 0, NO_DEADLINE);
        market.mintSets(ROUND, mintAmt);
        vm.stopPrank();

        (uint256 yes, uint256 no) = market.balancesOf(ROUND, alice);
        _endRoundWith(yesWins ? THRESHOLD + 1 : THRESHOLD);
        market.resolve(ROUND);

        vm.prank(alice);
        uint256 payout = market.claim(ROUND);
        assertEq(payout, yesWins ? yes : no, "payout must be exactly the winning balance");
    }

    /// The flagship property: for any mix of LPs (all tiers), bettors, set
    /// minters and any outcome, everyone can always exit in full and the
    /// contract retains only dead-share reserves plus rounding dust.
    function testFuzz_lifecycleConservation(
        uint256[3] memory lpAmounts,
        uint256[3] memory betAmounts,
        uint8 dirMask,
        uint256 mintAmount,
        uint256 finalCount
    ) public {
        uint16[3] memory tiers = [TIER_LOW, TIER_MID, TIER_HIGH];
        address[3] memory bettors = [alice, bob, carol];

        for (uint256 i = 0; i < 3; i++) {
            uint256 liq = bound(lpAmounts[i], 1e15, 300_000e18);
            vm.prank(i % 2 == 0 ? lpAda : lpBen);
            market.addLiquidity(ROUND, tiers[i], liq, 5_000, 0, NO_DEADLINE);
        }
        for (uint256 i = 0; i < 3; i++) {
            uint256 amount = bound(betAmounts[i], 1, 300_000e18);
            vm.prank(bettors[i]);
            if ((dirMask >> i) & 1 == 1) market.betYesBest(ROUND, amount, 0, NO_DEADLINE);
            else market.betNo(ROUND, tiers[i], amount, 0, NO_DEADLINE);
        }
        mintAmount = bound(mintAmount, 2, 100_000e18);
        vm.startPrank(carol);
        market.mintSets(ROUND, mintAmount);
        market.redeemSets(ROUND, mintAmount / 2);
        vm.stopPrank();

        _endRoundWith(bound(finalCount, 0, 1e30));
        market.resolve(ROUND);

        // Everyone exits everything they possibly can.
        address[5] memory everyone = [lpAda, lpBen, alice, bob, carol];
        uint256 contractHas = cst.balanceOf(address(market));
        uint256 paidOut;
        for (uint256 i = 0; i < everyone.length; i++) {
            for (uint256 t = 0; t < 3; t++) {
                (uint256 shares,) = market.lpPositionOf(ROUND, tiers[t], everyone[i]);
                if (shares > 0) {
                    vm.prank(everyone[i]);
                    (,, uint256 fees) = market.removeLiquidity(ROUND, tiers[t], shares, 0, 0, NO_DEADLINE);
                    paidOut += fees;
                }
            }
            vm.prank(everyone[i]);
            paidOut += market.claim(ROUND);
        }

        assertLe(paidOut, contractHas, "paid out more than the contract held");

        // Exact conservation: what remains is precisely the CST backing the
        // winning-side tokens still locked under the dead shares, plus the
        // unclaimable fee-rounding escrow. Not one wei more or less.
        (,, bool yesWon,,,,) = market.roundState(ROUND);
        uint256 expectedRetained;
        for (uint256 t = 0; t < 3; t++) {
            (uint256 rYl, uint256 rNl, uint256 sharesLeft,, uint256 feeLeft) = market.pool(ROUND, tiers[t]);
            assertEq(sharesLeft, DEAD_SHARES, "only dead shares may remain");
            expectedRetained += feeLeft + (yesWon ? rYl : rNl);
        }
        assertEq(cst.balanceOf(address(market)), expectedRetained, "retained CST diverged from liabilities");
    }

    /// Post-resolution solvency for any partial-exit order: whoever claims,
    /// in whatever order, the contract can always pay (no revert, balances
    /// never go negative). Exercised by claiming in fuzzed order.
    function testFuzz_claimOrderIndependence(uint256 orderSeed, uint256 betA, uint256 betB, bool yesWins) public {
        betA = bound(betA, 1, 200_000e18);
        betB = bound(betB, 1, 200_000e18);
        _seedPool(TIER_LOW, LIQ);
        vm.prank(alice);
        market.betYes(ROUND, TIER_LOW, betA, 0, NO_DEADLINE);
        vm.prank(bob);
        market.betNo(ROUND, TIER_LOW, betB, 0, NO_DEADLINE);

        _endRoundWith(yesWins ? THRESHOLD + 7 : THRESHOLD);
        market.resolve(ROUND);

        address[3] memory order;
        // Three claimants in a fuzzed order (lpAda exits liquidity first).
        (uint256 adaShares,) = market.lpPositionOf(ROUND, TIER_LOW, lpAda);
        vm.prank(lpAda);
        market.removeLiquidity(ROUND, TIER_LOW, adaShares, 0, 0, NO_DEADLINE);
        if (orderSeed % 3 == 0) order = [alice, bob, lpAda];
        else if (orderSeed % 3 == 1) order = [bob, lpAda, alice];
        else order = [lpAda, alice, bob];

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(order[i]);
            market.claim(ROUND); // must never revert for lack of funds
        }
        vm.prank(lpAda);
        market.claimFees(ROUND, TIER_LOW);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _tierAt(uint256 seed) internal pure returns (uint16) {
        uint16[3] memory tiers = [TIER_LOW, TIER_MID, TIER_HIGH];
        return tiers[seed % 3];
    }

    function _ceilDivHelper(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}

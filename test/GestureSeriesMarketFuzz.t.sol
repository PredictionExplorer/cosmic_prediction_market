// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {GestureSeriesMarket} from "../src/GestureSeriesMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";
import {SeriesTestBase} from "./utils/SeriesTestBase.sol";

/// @dev Exposes the internal AMM math for direct property fuzzing.
contract SeriesHarness is GestureSeriesMarket {
    constructor(ICosmicSignatureGame game_) GestureSeriesMarket(game_) {}

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
        harness = new SeriesHarness(ICosmicSignatureGame(address(game)));
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
    // Opening the pool
    // ------------------------------------------------------------------

    /// Opening at any probability and declaration conserves tokens exactly,
    /// prices the pool at the requested probability, and makes the sole
    /// voter's declaration the pool fee.
    function testFuzz_openPoolAtAnyProbabilityAndFee(uint256 liq, uint256 prob, uint256 declSeed) public {
        liq = bound(liq, 1e15, 1e24);
        prob = bound(prob, 100, 9_900);
        uint16 decl = uint16(bound(declSeed, 0, MAX_FEE_BPS));

        vm.prank(lpAda);
        uint256 shares = market.addLiquidity(ROUND, liq, decl, prob, 0, NO_DEADLINE);

        (uint256 rY, uint256 rN) = _reserves(ROUND);
        (uint256 yes, uint256 no) = market.balancesOf(ROUND, lpAda);
        assertEq(rY + yes, liq, "YES tokens conserved");
        assertEq(rN + no, liq, "NO tokens conserved");
        assertEq(shares, liq - DEAD_SHARES, "shares = deposit minus dead shares");
        assertEq(_totalShares(ROUND), liq);
        assertApproxEqAbs(_probBps(ROUND), prob, 1, "opening odds off");
        assertEq(market.currentFeeBps(ROUND), decl, "sole voter sets the fee");
        assertEq(_feeWeight(ROUND), liq * uint256(decl), "ledger seeded incl. dead shares");
    }

    // ------------------------------------------------------------------
    // The fee vote
    // ------------------------------------------------------------------

    /// The flagship fee property: after ANY sequence of adds (with fresh
    /// declarations), re-votes and removes by two LPs, the ledger equals the
    /// naive sum over all holders, and the average equals ledger / shares.
    function testFuzz_feeLedgerMatchesNaiveRecomputation(
        uint256[3] memory amounts,
        uint256[3] memory decls,
        uint256[3] memory actions,
        uint256 openDecl
    ) public {
        uint16 opener = uint16(bound(openDecl, 0, MAX_FEE_BPS));
        _seedPoolWith(lpAda, LIQ, opener, 5_000);

        address[2] memory lps = [lpAda, lpBen];
        for (uint256 i = 0; i < 3; i++) {
            address lp = lps[i % 2];
            uint16 decl = uint16(bound(decls[i], 0, MAX_FEE_BPS));
            uint256 action = actions[i] % 3;
            if (action == 0) {
                uint256 amount = bound(amounts[i], 1, 1e23);
                vm.prank(lp);
                market.addLiquidity(ROUND, amount, decl, 0, 0, NO_DEADLINE);
            } else if (action == 1) {
                uint256 shares = _lpShares(ROUND, lp);
                if (shares == 0) continue;
                vm.prank(lp);
                market.updateFeeDeclaration(ROUND, decl);
            } else {
                uint256 shares = _lpShares(ROUND, lp);
                if (shares == 0) continue;
                uint256 toBurn = bound(amounts[i], 1, shares);
                vm.prank(lp);
                market.removeLiquidity(ROUND, toBurn, 0, 0, NO_DEADLINE);
            }
        }

        // Naive recomputation over every holder, dead shares included.
        uint256 naive = _lpShares(ROUND, lpAda) * uint256(_lpDeclaration(ROUND, lpAda)) + _lpShares(ROUND, lpBen)
            * uint256(_lpDeclaration(ROUND, lpBen)) + _lpShares(ROUND, address(0))
            * uint256(_lpDeclaration(ROUND, address(0)));
        assertEq(_feeWeight(ROUND), naive, "ledger diverged from naive sum");
        assertEq(market.currentFeeBps(ROUND), naive / _totalShares(ROUND), "average is ledger / shares");
        assertLe(market.currentFeeBps(ROUND), MAX_FEE_BPS, "average above the cap");
    }

    /// A weighted average always lies within [min, max] of its holders'
    /// declarations (dead shares included).
    function testFuzz_feeAverageBoundedByDeclarations(uint256 liqA, uint256 liqB, uint256 dA, uint256 dB) public {
        liqA = bound(liqA, 1e15, 1e24);
        liqB = bound(liqB, 1, 1e24);
        uint16 declA = uint16(bound(dA, 0, MAX_FEE_BPS));
        uint16 declB = uint16(bound(dB, 0, MAX_FEE_BPS));

        _seedPoolWith(lpAda, liqA, declA, 5_000);
        vm.prank(lpBen);
        try market.addLiquidity(ROUND, liqB, declB, 0, 0, NO_DEADLINE) {}
        catch {
            return; // deposit too small to mint one share
        }

        uint256 lo = declA < declB ? declA : declB;
        uint256 hi = declA > declB ? declA : declB;
        uint256 avg = market.currentFeeBps(ROUND);
        assertGe(avg, lo, "average below every declaration");
        assertLe(avg, hi, "average above every declaration");
    }

    /// Raising your declaration can never lower the average; lowering it can
    /// never raise the average.
    function testFuzz_feeVoteMonotonicity(uint256 liqB, uint256 d0, uint256 d1) public {
        _seedPoolWith(lpAda, LIQ, 500, 5_000);
        liqB = bound(liqB, 1e15, 1e24);
        uint16 before_ = uint16(bound(d0, 0, MAX_FEE_BPS));
        uint16 after_ = uint16(bound(d1, 0, MAX_FEE_BPS));

        vm.prank(lpBen);
        market.addLiquidity(ROUND, liqB, before_, 0, 0, NO_DEADLINE);
        uint256 avgBefore = market.currentFeeBps(ROUND);

        vm.prank(lpBen);
        market.updateFeeDeclaration(ROUND, after_);
        uint256 avgAfter = market.currentFeeBps(ROUND);

        if (after_ > before_) assertGe(avgAfter, avgBefore, "raising a vote lowered the average");
        else if (after_ < before_) assertLe(avgAfter, avgBefore, "lowering a vote raised the average");
        else assertEq(avgAfter, avgBefore, "identical vote moved the average");
    }

    /// Fee escrow is exact to the wei even while the fee changes between
    /// bets: feeReserve equals the sum of floor(cstIn * feeAtBet / BPS).
    function testFuzz_feeEscrowExactUnderChangingVotes(uint256[3] memory amounts, uint256[3] memory votes) public {
        _seedPoolWith(lpAda, LIQ, 300, 5_000);

        uint256 expectedEscrow;
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(lpAda);
            market.updateFeeDeclaration(ROUND, uint16(bound(votes[i], 0, MAX_FEE_BPS)));

            uint256 amount = bound(amounts[i], 1, 200_000e18);
            uint256 feeNow = market.currentFeeBps(ROUND);
            vm.prank(alice);
            if (i % 2 == 0) market.betYes(ROUND, amount, 0, NO_DEADLINE);
            else market.betNo(ROUND, amount, 0, NO_DEADLINE);
            expectedEscrow += amount * feeNow / BPS;
        }
        assertEq(_feeReserve(ROUND), expectedEscrow, "escrow diverged from per-bet fee sum");

        // All pending claims fit inside the escrow, and paying them out
        // leaves only accumulator dust.
        uint256 adaPending = _lpPending(ROUND, lpAda);
        assertLe(adaPending, expectedEscrow, "owed more than escrowed");
        vm.prank(lpAda);
        assertEq(market.claimFees(ROUND), adaPending);
        assertLt(_feeReserve(ROUND), 1e6, "excess fee dust");
    }

    /// Fee earnings split by shares regardless of declarations: two LPs with
    /// arbitrary votes earn identical per-share rates.
    function testFuzz_feeEarningsProRataByShares(uint256 amount, uint256 dA, uint256 dB, uint256 liqB) public {
        amount = bound(amount, 1e6, 200_000e18);
        liqB = bound(liqB, 1e15, 1e24);
        _seedPoolWith(lpAda, LIQ, uint16(bound(dA, 0, MAX_FEE_BPS)), 5_000);
        vm.prank(lpBen);
        market.addLiquidity(ROUND, liqB, uint16(bound(dB, 0, MAX_FEE_BPS)), 0, 0, NO_DEADLINE);

        vm.prank(alice);
        market.betYes(ROUND, amount, 0, NO_DEADLINE);

        (uint256 adaShares, uint256 adaPending,) = market.lpPositionOf(ROUND, lpAda);
        (uint256 benShares, uint256 benPending,) = market.lpPositionOf(ROUND, lpBen);
        assertApproxEqAbs(
            adaPending * 1e18 / adaShares, benPending * 1e18 / benShares, 1e6, "per-share fee rate differs between LPs"
        );
    }

    // ------------------------------------------------------------------
    // Joining and removing liquidity
    // ------------------------------------------------------------------

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

        _seedPoolWith(lpAda, liq, FEE, prob);
        vm.prank(alice);
        if (skewYes) market.betYes(ROUND, skew, 0, NO_DEADLINE);
        else market.betNo(ROUND, skew, 0, NO_DEADLINE);

        (uint256 rY, uint256 rN) = _reserves(ROUND);
        uint256 m = rY > rN ? rY : rN;
        uint256 probBefore = _probBps(ROUND);
        uint256 totalBefore = _totalShares(ROUND);

        vm.prank(lpBen);
        try market.addLiquidity(ROUND, add, FEE, 0, 0, NO_DEADLINE) returns (uint256 shares) {
            assertGt(shares, 0);
            assertApproxEqAbs(_probBps(ROUND), probBefore, 1, "join moved the price");

            (uint256 rY2, uint256 rN2) = _reserves(ROUND);
            (uint256 yes, uint256 no) = market.balancesOf(ROUND, lpBen);
            assertEq(rY2 - rY + yes, add, "YES tokens conserved on join");
            assertEq(rN2 - rN + no, add, "NO tokens conserved on join");

            uint256 total2 = _totalShares(ROUND);
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

    /// Add-then-remove immediately can never pay out more CST-equivalent
    /// value than went in, for any pool state (no free-mint pump).
    function testFuzz_addRemoveRoundtripNeverProfits(uint256 skew, bool skewYes, uint256 add) public {
        skew = bound(skew, 1, 1e23);
        add = bound(add, 1e6, 1e24);
        _seedPool(LIQ);
        vm.prank(alice);
        if (skewYes) market.betYes(ROUND, skew, 0, NO_DEADLINE);
        else market.betNo(ROUND, skew, 0, NO_DEADLINE);

        uint256 cstBefore = cst.balanceOf(lpBen);
        vm.startPrank(lpBen);
        uint256 shares = market.addLiquidity(ROUND, add, FEE, 0, 0, NO_DEADLINE);
        market.removeLiquidity(ROUND, shares, 0, 0, NO_DEADLINE);
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

    /// Quotes must exactly equal executed bets, from any skewed pool state
    /// and any fee vote — including right after a re-vote.
    function testFuzz_quotesMatchBetsFromAnyState(uint256 skew, bool skewYes, uint256 amount, uint256 newVote) public {
        skew = bound(skew, 1, 1e23);
        amount = bound(amount, 1, 1e23);
        _seedPool(LIQ);

        vm.prank(bob);
        if (skewYes) market.betYes(ROUND, skew, 0, NO_DEADLINE);
        else market.betNo(ROUND, skew, 0, NO_DEADLINE);
        vm.prank(lpAda);
        market.updateFeeDeclaration(ROUND, uint16(bound(newVote, 0, MAX_FEE_BPS)));

        uint256 quotedYes = market.quoteBetYes(ROUND, amount);
        uint256 quotedNo = market.quoteBetNo(ROUND, amount);

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        assertEq(market.betYes(ROUND, amount, 0, NO_DEADLINE), quotedYes, "YES quote mismatch");
        vm.revertToState(snap);
        vm.prank(alice);
        assertEq(market.betNo(ROUND, amount, 0, NO_DEADLINE), quotedNo, "NO quote mismatch");
    }

    /// After ANY sequence of bets: the probability stays in (0, 10000), k
    /// never decreases, reserves never empty, and every bet pays at least its
    /// net input in tokens.
    function testFuzz_arbitraryBetSequenceKeepsPoolHealthy(uint256[4] memory amounts, uint8 dirMask) public {
        _seedPool(LIQ);
        (uint256 rY, uint256 rN) = _reserves(ROUND);
        uint256 kBefore = rY * rN;

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = bound(amounts[i], 1, 250_000e18);
            uint256 feeNow = market.currentFeeBps(ROUND);
            vm.prank(alice);
            uint256 tokensOut = (dirMask >> i) & 1 == 1
                ? market.betYes(ROUND, amount, 0, NO_DEADLINE)
                : market.betNo(ROUND, amount, 0, NO_DEADLINE);
            assertGe(tokensOut, amount - amount * feeNow / BPS, "token cost above 1 CST");

            (rY, rN) = _reserves(ROUND);
            assertGe(rY, 1, "YES reserve emptied");
            assertGe(rN, 1, "NO reserve emptied");
            uint256 prob = _probBps(ROUND);
            assertGt(prob, 0, "probability pinned to 0");
            assertLt(prob, BPS, "probability pinned to 1");
            assertGe(rY * rN, kBefore, "k decreased");
            kBefore = rY * rN;
        }
    }

    /// A bet split into two parts must give (near) identical tokens as one
    /// bet: path independence up to integer rounding. (Bets never change the
    /// fee, so the fee is constant across the split.)
    function testFuzz_splitBetEquivalentToSingleBet(uint256 a, uint256 b) public {
        a = bound(a, 1e18, 100_000e18);
        b = bound(b, 1e18, 100_000e18);
        _seedPool(LIQ);

        uint256 snap = vm.snapshotState();
        vm.startPrank(alice);
        uint256 split = market.betYes(ROUND, a, 0, NO_DEADLINE) + market.betYes(ROUND, b, 0, NO_DEADLINE);
        vm.stopPrank();

        vm.revertToState(snap);
        vm.prank(alice);
        uint256 single = market.betYes(ROUND, a + b, 0, NO_DEADLINE);

        assertApproxEqAbs(split, single, 4, "path dependence beyond rounding");
    }

    /// Any minTokensOut above the true output must revert — the guard that
    /// defeats liquidity pulls, sandwiches, and fee-vote jumps alike.
    function testFuzz_slippageGuardAlwaysEnforced(uint256 amount, uint256 excess) public {
        amount = bound(amount, 1, 500_000e18);
        excess = bound(excess, 1, type(uint128).max);
        _seedPool(LIQ);
        uint256 quoted = market.quoteBetYes(ROUND, amount);

        vm.expectRevert(GestureSeriesMarket.Slippage.selector);
        vm.prank(alice);
        market.betYes(ROUND, amount, quoted + excess, NO_DEADLINE);
    }

    /// No money pump: betting both sides and redeeming pairs pre-resolution
    /// can never withdraw more CST than went in, against any skewed pool.
    function testFuzz_noProfitExtractionPreResolution(uint256 skew, bool skewYes, uint256 a, uint256 b) public {
        skew = bound(skew, 1, 500_000e18);
        a = bound(a, 1, 400_000e18);
        b = bound(b, 1, 400_000e18);
        _seedPool(LIQ);

        vm.prank(bob);
        if (skewYes) market.betYes(ROUND, skew, 0, NO_DEADLINE);
        else market.betNo(ROUND, skew, 0, NO_DEADLINE);

        uint256 aliceStart = cst.balanceOf(alice);
        vm.startPrank(alice);
        market.betYes(ROUND, a, 0, NO_DEADLINE);
        market.betNo(ROUND, b, 0, NO_DEADLINE);
        (uint256 yes, uint256 no) = market.balancesOf(ROUND, alice);
        market.redeemSets(ROUND, yes < no ? yes : no);
        vm.stopPrank();

        assertLe(cst.balanceOf(alice), aliceStart, "pre-resolution profit extraction");
    }

    // ------------------------------------------------------------------
    // Lifecycle & resolution
    // ------------------------------------------------------------------

    /// Resolution truth table, for any counts and any phase: a FUTURE round
    /// is never resolvable no matter what the game data shows; after the
    /// round ends YES wins iff final > threshold (ties pay NO); early
    /// resolution exists iff the live count already exceeds the threshold,
    /// and always resolves YES.
    function testFuzz_resolutionMatchesStrictComparison(uint256 threshold, uint256 finalCount, uint8 phase) public {
        threshold = bound(threshold, 0, 1e30);
        finalCount = bound(finalCount, 0, 1e30);
        game.setNumBids(ROUND - 1, threshold);
        _seedPool(LIQ);

        if (phase % 3 == 0) {
            // Future: a round funded ahead of time is not resolvable no
            // matter what counts exist anywhere in the game.
            uint256 future = ROUND + 1;
            _seedRoundPool(future, lpAda, LIQ);
            game.setNumBids(future, finalCount);
            vm.expectRevert(GestureSeriesMarket.NotResolvable.selector);
            market.resolve(future);
        } else if (phase % 3 == 1) {
            game.setNumBids(ROUND, finalCount); // round stays live
            if (finalCount > threshold) {
                market.resolve(ROUND);
                RoundView memory v = _state(ROUND);
                assertTrue(v.resolved);
                assertTrue(v.yesWon, "early resolution can only be YES");
            } else {
                vm.expectRevert(GestureSeriesMarket.NotResolvable.selector);
                market.resolve(ROUND);
            }
        } else {
            _endRoundWith(finalCount);
            market.resolve(ROUND);
            assertEq(_state(ROUND).yesWon, finalCount > threshold, "strict comparison violated");
        }
    }

    /// Once the live count crosses the threshold, every bet and liquidity add
    /// reverts — there is no block in which a decided outcome can be traded.
    function testFuzz_noTradingOnDecidedOutcome(uint256 count) public {
        _seedPool(LIQ);
        count = bound(count, THRESHOLD + 1, 1e30);
        game.setNumBids(ROUND, count);

        vm.startPrank(alice);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.betYes(ROUND, 1e18, 0, NO_DEADLINE);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.betNo(ROUND, 1e18, 0, NO_DEADLINE);
        vm.stopPrank();
        vm.prank(lpBen);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.addLiquidity(ROUND, 1e18, FEE, 0, 0, NO_DEADLINE);
    }

    /// Winning tokens always pay exactly 1 CST each, losing exactly 0, no
    /// matter how the position was assembled.
    function testFuzz_claimPaysExactlyOneCstPerWinningToken(uint256 a, uint256 b, uint256 mintAmt, bool yesWins)
        public
    {
        a = bound(a, 1, 300_000e18);
        b = bound(b, 1, 300_000e18);
        mintAmt = bound(mintAmt, 1, 100_000e18);
        _seedPool(LIQ);

        vm.startPrank(alice);
        market.betYes(ROUND, a, 0, NO_DEADLINE);
        market.betNo(ROUND, b, 0, NO_DEADLINE);
        market.mintSets(ROUND, mintAmt);
        vm.stopPrank();

        (uint256 yes, uint256 no) = market.balancesOf(ROUND, alice);
        _endRoundWith(yesWins ? THRESHOLD + 1 : THRESHOLD);
        market.resolve(ROUND);

        vm.prank(alice);
        uint256 payout = market.claim(ROUND);
        assertEq(payout, yesWins ? yes : no, "payout must be exactly the winning balance");
    }

    /// The flagship property: for any mix of LPs (with any fee votes and a
    /// mid-life re-vote), bettors, set minters and any outcome, everyone can
    /// always exit in full and the contract retains only dead-share reserves
    /// plus fee-rounding dust — exactly.
    function testFuzz_lifecycleConservation(
        uint256[2] memory lpAmounts,
        uint256[2] memory lpVotes,
        uint256[3] memory betAmounts,
        uint8 dirMask,
        uint256 mintAmount,
        uint256 finalCount,
        uint256 revote
    ) public {
        address[2] memory lps = [lpAda, lpBen];
        address[3] memory bettors = [alice, bob, carol];

        _seedPoolWith(lpAda, bound(lpAmounts[0], 1e15, 300_000e18), uint16(bound(lpVotes[0], 0, MAX_FEE_BPS)), 5_000);
        vm.prank(lpBen);
        try market.addLiquidity(
            ROUND, bound(lpAmounts[1], 1e15, 300_000e18), uint16(bound(lpVotes[1], 0, MAX_FEE_BPS)), 0, 0, NO_DEADLINE
        ) {}
            catch {}

        for (uint256 i = 0; i < 3; i++) {
            if (i == 1) {
                // A mid-life re-vote changes the fee for later bets.
                vm.prank(lpAda);
                market.updateFeeDeclaration(ROUND, uint16(bound(revote, 0, MAX_FEE_BPS)));
            }
            uint256 amount = bound(betAmounts[i], 1, 300_000e18);
            vm.prank(bettors[i]);
            if ((dirMask >> i) & 1 == 1) market.betYes(ROUND, amount, 0, NO_DEADLINE);
            else market.betNo(ROUND, amount, 0, NO_DEADLINE);
        }
        mintAmount = bound(mintAmount, 2, 100_000e18);
        vm.startPrank(carol);
        market.mintSets(ROUND, mintAmount);
        market.redeemSets(ROUND, mintAmount / 2);
        vm.stopPrank();

        _endRoundWith(bound(finalCount, 0, 1e30));
        market.resolve(ROUND);

        // Everyone exits everything they possibly can.
        uint256 contractHas = cst.balanceOf(address(market));
        uint256 paidOut;
        for (uint256 i = 0; i < 2; i++) {
            uint256 shares = _lpShares(ROUND, lps[i]);
            if (shares > 0) {
                vm.prank(lps[i]);
                (,, uint256 fees) = market.removeLiquidity(ROUND, shares, 0, 0, NO_DEADLINE);
                paidOut += fees;
            }
        }
        address[5] memory everyone = [lpAda, lpBen, alice, bob, carol];
        for (uint256 i = 0; i < everyone.length; i++) {
            vm.prank(everyone[i]);
            paidOut += market.claim(ROUND);
        }

        assertLe(paidOut, contractHas, "paid out more than the contract held");

        // Exact conservation: what remains is precisely the CST backing the
        // winning-side tokens still locked under the dead shares, plus the
        // unclaimable fee-rounding escrow. Not one wei more or less.
        RoundView memory v = _state(ROUND);
        bool yesWon = v.yesWon;
        assertTrue(v.resolved);
        (uint256 rYl, uint256 rNl, uint256 sharesLeft,, uint256 feeLeft,,) = market.pool(ROUND);
        assertEq(sharesLeft, DEAD_SHARES, "only dead shares may remain");
        assertEq(
            cst.balanceOf(address(market)), feeLeft + (yesWon ? rYl : rNl), "retained CST diverged from liabilities"
        );
    }

    // ------------------------------------------------------------------
    // Future rounds & threshold locking
    // ------------------------------------------------------------------

    /// The locked threshold always equals the previous round's final count,
    /// whichever entry point locks it and however many rounds pass before the
    /// first touch.
    function testFuzz_thresholdLockMatchesFinalPrevCount(uint256 prevFinal, uint256 delaySeed, uint256 touchSeed)
        public
    {
        uint256 future = ROUND + 1;
        prevFinal = bound(prevFinal, 0, 1e30);
        uint256 delay = bound(delaySeed, 0, 3); // extra rounds before the first touch
        uint256 touch = touchSeed % 3;

        _seedRoundPool(future, lpAda, LIQ);
        assertFalse(_state(future).thresholdKnown);

        _endRoundWith(prevFinal); // ROUND ends; `future` becomes current
        // Adds and bets only work while the round is current-or-future, so a
        // delayed first touch necessarily happens via resolve.
        bool viaResolve = touch == 2 || delay > 0;
        if (delay > 0) game.setRoundNum(future + delay);
        if (viaResolve && game.roundNum() == future) game.setRoundNum(future + 1);

        vm.expectEmit(true, false, false, true);
        emit GestureSeriesMarket.ThresholdLocked(future, prevFinal);
        if (viaResolve) {
            market.resolve(future);
        } else if (touch == 0) {
            vm.prank(lpBen);
            market.addLiquidity(future, 1e18, FEE, 0, 0, NO_DEADLINE);
        } else {
            vm.prank(alice);
            market.betYes(future, 1e18, 0, NO_DEADLINE);
        }
        assertEq(_state(future).threshold, prevFinal, "locked threshold diverged from the final count");
    }

    /// The flagship conservation property extended across phases: positions
    /// taken BEFORE the round exists, through the threshold reveal, into the
    /// live round and resolution — everyone exits in full and the contract
    /// retains exactly dead-share reserves plus fee dust.
    function testFuzz_crossPhaseLifecycleConservation(
        uint256 liq,
        uint256 futureBet,
        uint256 currentBet,
        uint256 revealedThreshold,
        uint256 finalCount,
        bool futureBetYes,
        bool currentBetYes
    ) public {
        uint256 future = ROUND + 1;
        liq = bound(liq, 1e15, 300_000e18);
        futureBet = bound(futureBet, 1, 300_000e18);
        currentBet = bound(currentBet, 1, 300_000e18);
        revealedThreshold = bound(revealedThreshold, 0, 1e30);
        finalCount = bound(finalCount, 0, 1e30);

        // Future phase: the market exists before its round does.
        _seedRoundPool(future, lpAda, liq);
        vm.prank(alice);
        if (futureBetYes) market.betYes(future, futureBet, 0, NO_DEADLINE);
        else market.betNo(future, futureBet, 0, NO_DEADLINE);

        // Reveal: ROUND ends with an arbitrary count; more trading after it.
        _endRoundWith(revealedThreshold);
        vm.prank(bob);
        if (currentBetYes) market.betYes(future, currentBet, 0, NO_DEADLINE);
        else market.betNo(future, currentBet, 0, NO_DEADLINE);

        // The round runs and ends with an arbitrary count.
        game.setNumBids(future, finalCount);
        game.setRoundNum(future + 1);
        market.resolve(future);

        address[3] memory everyone = [lpAda, alice, bob];
        for (uint256 i = 0; i < everyone.length; i++) {
            uint256 shares = _lpShares(future, everyone[i]);
            if (shares > 0) {
                vm.prank(everyone[i]);
                market.removeLiquidity(future, shares, 0, 0, NO_DEADLINE);
            }
            vm.prank(everyone[i]);
            market.claimFees(future);
            vm.prank(everyone[i]);
            market.claim(future);
        }

        (uint256 rYl, uint256 rNl, uint256 sharesLeft,, uint256 feeLeft,,) = market.pool(future);
        assertEq(sharesLeft, DEAD_SHARES, "only dead shares may remain");
        assertEq(
            cst.balanceOf(address(market)),
            feeLeft + (_state(future).yesWon ? rYl : rNl),
            "retained CST is not exactly dead-share reserves plus fee dust"
        );
    }

    // ------------------------------------------------------------------
    // LP actions can never change what a bettor is owed
    // ------------------------------------------------------------------

    /// After a bettor's fill, ANY sequence of LP maneuvers — partial or full
    /// rugs, fresh joins, fee re-votes — leaves the bettor's balance and
    /// resolution payout exactly as filled: LPs cannot touch a filled bet.
    function testFuzz_lpActionsNeverChangeABettorsPayout(
        uint256 betAmount,
        bool betIsYes,
        uint256[3] memory lpAmounts,
        uint256[3] memory lpActions,
        bool yesWins
    ) public {
        betAmount = bound(betAmount, 1, 200_000e18);
        _seedPool(LIQ);

        vm.prank(alice);
        uint256 tokensOut =
            betIsYes ? market.betYes(ROUND, betAmount, 0, NO_DEADLINE) : market.betNo(ROUND, betAmount, 0, NO_DEADLINE);

        // Arbitrary post-fill LP maneuvering, including a full rug.
        for (uint256 i = 0; i < 3; i++) {
            uint256 action = lpActions[i] % 3;
            if (action == 0) {
                uint256 shares = _lpShares(ROUND, lpAda);
                if (shares == 0) continue;
                vm.prank(lpAda);
                market.removeLiquidity(ROUND, bound(lpAmounts[i], 1, shares), 0, 0, NO_DEADLINE);
            } else if (action == 1) {
                (uint256 rY, uint256 rN) = _reserves(ROUND);
                if (rY == 0 || rN == 0) continue;
                vm.prank(lpBen);
                try market.addLiquidity(ROUND, bound(lpAmounts[i], 1e15, 100_000e18), 1_000, 0, 0, NO_DEADLINE) {}
                    catch {}
            } else {
                if (_lpShares(ROUND, lpAda) == 0) continue;
                vm.prank(lpAda);
                market.updateFeeDeclaration(ROUND, uint16(bound(lpAmounts[i], 0, MAX_FEE_BPS)));
            }
        }

        (uint256 yesBal, uint256 noBal) = market.balancesOf(ROUND, alice);
        assertEq(betIsYes ? yesBal : noBal, tokensOut, "LP actions altered the bettor's balance");

        _endRoundWith(yesWins ? THRESHOLD + 1 : THRESHOLD);
        market.resolve(ROUND);
        vm.prank(alice);
        uint256 payout = market.claim(ROUND);
        assertEq(
            payout,
            betIsYes == yesWins ? tokensOut : 0,
            "payout must be exactly the filled tokens (or zero if the bet lost)"
        );
    }

    /// Post-resolution solvency for any claim order: whoever claims, in
    /// whatever order, the contract can always pay.
    function testFuzz_claimOrderIndependence(uint256 orderSeed, uint256 betA, uint256 betB, bool yesWins) public {
        betA = bound(betA, 1, 200_000e18);
        betB = bound(betB, 1, 200_000e18);
        _seedPool(LIQ);
        vm.prank(alice);
        market.betYes(ROUND, betA, 0, NO_DEADLINE);
        vm.prank(bob);
        market.betNo(ROUND, betB, 0, NO_DEADLINE);

        _endRoundWith(yesWins ? THRESHOLD + 7 : THRESHOLD);
        market.resolve(ROUND);

        uint256 adaShares = _lpShares(ROUND, lpAda);
        vm.prank(lpAda);
        market.removeLiquidity(ROUND, adaShares, 0, 0, NO_DEADLINE);

        address[3] memory order;
        if (orderSeed % 3 == 0) order = [alice, bob, lpAda];
        else if (orderSeed % 3 == 1) order = [bob, lpAda, alice];
        else order = [lpAda, alice, bob];

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(order[i]);
            market.claim(ROUND); // must never revert for lack of funds
        }
        vm.prank(lpAda);
        market.claimFees(ROUND);
    }
}

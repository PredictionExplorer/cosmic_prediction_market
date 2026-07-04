// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GestureSeriesMarket} from "../src/GestureSeriesMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";
import {SeriesTestBase} from "./utils/SeriesTestBase.sol";
import {MockGame, ReenteringCst, FalseReturningCst, IReentryHook} from "./utils/Mocks.sol";

/// @notice Attacker that reenters `claim()` while the market is paying it out.
contract ClaimReenterer is IReentryHook {
    GestureSeriesMarket public immutable market;
    uint256 public immutable roundId;
    bool public reentryReverted;
    bool internal reentered;

    constructor(GestureSeriesMarket market_, uint256 roundId_) {
        market = market_;
        roundId = roundId_;
    }

    function claimOnce() external returns (uint256) {
        return market.claim(roundId);
    }

    function onCstReceived() external {
        if (reentered) return;
        reentered = true;
        try market.claim(roundId) {
            reentryReverted = false;
        } catch {
            reentryReverted = true;
        }
    }
}

/// @notice Attacker that reenters the market while receiving an LP fee payout,
/// trying to double-collect fees or double-remove liquidity.
contract LpReenterer is IReentryHook {
    GestureSeriesMarket public immutable market;
    uint256 public immutable roundId;
    bool public feeReentryReverted;
    bool public removeReentryReverted;
    bool internal reentered;

    constructor(GestureSeriesMarket market_, uint256 roundId_) {
        market = market_;
        roundId = roundId_;
    }

    function addLiquidity(uint256 amount) external {
        market.addLiquidity(roundId, amount, 200, 5_000, 0, type(uint256).max);
    }

    function claimFeesOnce() external returns (uint256) {
        return market.claimFees(roundId);
    }

    function onCstReceived() external {
        if (reentered) return;
        reentered = true;
        try market.claimFees(roundId) {
            feeReentryReverted = false;
        } catch {
            feeReentryReverted = true;
        }
        try market.removeLiquidity(roundId, 1, 0, 0, type(uint256).max) {
            removeReentryReverted = false;
        } catch {
            removeReentryReverted = true;
        }
    }
}

/// @notice Adversarial and hostile-environment tests. Each test scripts a
/// concrete attack someone might actually try and proves the mitigation holds.
contract GestureSeriesMarketHardeningTest is SeriesTestBase {
    // ------------------------------------------------------------------
    // Front-running: liquidity pulls, sandwiches, fee jacks
    // ------------------------------------------------------------------

    /// THE original attack from the design discussion: an LP watches the
    /// mempool, sees a bet coming, and pulls their liquidity first so the bet
    /// executes into a near-empty pool at a terrible price. The bettor's
    /// minTokensOut (computed off the pre-pull quote) must revert the trade.
    function test_attack_lpPullsLiquidityBeforeBet() public {
        uint256 adaShares = _seedPool(LIQ);

        // Victim quotes 1000 CST -> YES and signs with 1% slippage tolerance.
        uint256 quoted = market.quoteBetYes(ROUND, 1_000e18);
        uint256 minOut = quoted * 99 / 100;

        // LP front-runs: pulls 95% of the pool.
        vm.prank(lpAda);
        market.removeLiquidity(ROUND, adaShares * 95 / 100, 0, 0, NO_DEADLINE);

        // The victim's transaction lands after the pull — and safely reverts.
        vm.prank(alice);
        vm.expectRevert(GestureSeriesMarket.Slippage.selector);
        market.betYes(ROUND, 1_000e18, minOut, NO_DEADLINE);

        // Without the guard the fill would have been catastrophically worse.
        assertLt(market.quoteBetYes(ROUND, 1_000e18), minOut, "sanity: the pull really degraded the price");
    }

    /// The weighted-fee analogue: a whale deposits a huge stake declared at
    /// the 10% cap right before the victim's bet, jacking the average fee.
    /// The victim's minTokensOut floor reverts the degraded fill exactly like
    /// a liquidity pull.
    function test_attack_feeJackSandwichBoundedBySlippage() public {
        _seedPoolWith(lpAda, LIQ, 100, 5_000); // pool opens at a 1% fee
        assertEq(market.currentFeeBps(ROUND), 100);

        // Victim quotes at the 1% fee and signs with 0.5% tolerance.
        uint256 quoted = market.quoteBetYes(ROUND, 2_000e18);
        uint256 minOut = quoted * 995 / 1_000;

        // Whale front-runs: 9x the pool declared at the 10% cap -> fee ~9.1%.
        vm.prank(bob);
        market.addLiquidity(ROUND, LIQ * 9, 1_000, 0, 0, NO_DEADLINE);
        assertGt(market.currentFeeBps(ROUND), 800, "sanity: the fee really jumped");

        // The victim's bet lands after the jack — and safely reverts.
        vm.prank(alice);
        vm.expectRevert(GestureSeriesMarket.Slippage.selector);
        market.betYes(ROUND, 2_000e18, minOut, NO_DEADLINE);
    }

    /// A whale voting the maximum can never push the fee beyond the 10% cap,
    /// and quotes always reflect exactly what execution charges.
    function test_attack_feeVoteWhaleIsCappded() public {
        _seedPoolWith(lpAda, LIQ, 1_000, 5_000);
        vm.prank(bob);
        market.addLiquidity(ROUND, LIQ * 100, 1_000, 0, 0, NO_DEADLINE);

        assertEq(market.currentFeeBps(ROUND), 1_000, "everyone at the cap -> exactly the cap");
        uint256 quoted = market.quoteBetYes(ROUND, 1_000e18);
        vm.prank(alice);
        assertEq(market.betYes(ROUND, 1_000e18, quoted, NO_DEADLINE), quoted, "quote == execution at the cap");
    }

    /// Classic sandwich: attacker buys YES ahead of the victim, the victim's
    /// bet would execute at the inflated price. The slippage bound caps the
    /// victim's loss at exactly the tolerance they chose.
    function test_attack_sandwichBoundedBySlippage() public {
        _seedPool(LIQ);
        uint256 quoted = market.quoteBetYes(ROUND, 2_000e18);
        uint256 minOut = quoted * 995 / 1_000; // 0.5% tolerance

        // Attacker front-runs with a large YES buy.
        vm.prank(bob);
        market.betYes(ROUND, 5_000e18, 0, NO_DEADLINE);

        // Victim is protected: execution would be below the signed floor.
        vm.prank(alice);
        vm.expectRevert(GestureSeriesMarket.Slippage.selector);
        market.betYes(ROUND, 2_000e18, minOut, NO_DEADLINE);
    }

    /// Stale transactions can't be replayed later at manipulated prices:
    /// every price-sensitive function honors its deadline.
    function test_attack_staleTransactionsRejectedByDeadline() public {
        _seedPool(LIQ);
        uint256 deadline = block.timestamp + 300;
        vm.warp(block.timestamp + 301);

        vm.startPrank(alice);
        vm.expectRevert(GestureSeriesMarket.DeadlineExpired.selector);
        market.betYes(ROUND, 1e18, 0, deadline);
        vm.expectRevert(GestureSeriesMarket.DeadlineExpired.selector);
        market.betNo(ROUND, 1e18, 0, deadline);
        vm.stopPrank();
        vm.startPrank(lpBen);
        vm.expectRevert(GestureSeriesMarket.DeadlineExpired.selector);
        market.addLiquidity(ROUND, 1_000e18, FEE, 0, 0, deadline);
        vm.expectRevert(GestureSeriesMarket.DeadlineExpired.selector);
        market.removeLiquidity(ROUND, 1, 0, 0, deadline);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // JIT liquidity
    // ------------------------------------------------------------------

    /// Just-in-time liquidity: an LP jumps in right before a big bet and out
    /// right after, skimming fees from passive LPs. The bounds that hold by
    /// construction: the JIT LP inherits zero pre-join fees, skims at most a
    /// pro-rata slice of the one bet it sniped, cannot extract more CASH than
    /// deposit + fees, and dilutes the passive LP by exactly the share ratio.
    function test_attack_jitLiquidityCannotExtractBeyondProRataFees() public {
        _seedPool(LIQ);
        // Fees accrued BEFORE the JIT join belong to Ada alone.
        vm.prank(carol);
        market.betYes(ROUND, 4_000e18, 0, NO_DEADLINE);
        uint256 adaPreJitFees = _lpPending(ROUND, lpAda);

        uint256 jitCash = cst.balanceOf(lpBen);
        vm.prank(lpBen);
        uint256 jitShares = market.addLiquidity(ROUND, LIQ, FEE, 0, 0, NO_DEADLINE);
        assertEq(_lpPending(ROUND, lpBen), 0, "JIT LP must not inherit pre-join fees");

        // The big bet the JIT LP is sniping.
        uint256 feeNow = market.currentFeeBps(ROUND);
        vm.prank(alice);
        market.betYes(ROUND, 10_000e18, 0, NO_DEADLINE);
        uint256 betFee = 10_000e18 * feeNow / BPS;
        uint256 totalShares = _totalShares(ROUND);

        // JIT LP exits immediately.
        vm.prank(lpBen);
        (,, uint256 jitFees) = market.removeLiquidity(ROUND, jitShares, 0, 0, NO_DEADLINE);
        assertLe(jitFees, betFee * jitShares / totalShares + 1, "JIT LP skimmed beyond pro-rata");

        // The passive LP keeps her pre-join fees in full plus her exact
        // pro-rata cut of the sniped bet — diluted by shares, nothing worse.
        // (Tolerance: the accumulator floors twice per fee event.)
        (uint256 adaShares, uint256 adaPending,) = market.lpPositionOf(ROUND, lpAda);
        uint256 roundingSlack = 2 * (adaShares / 1e18 + 1);
        assertGe(
            adaPending + roundingSlack, adaPreJitFees + betFee * adaShares / totalShares, "passive LP over-diluted"
        );

        // Cash-extraction bound: after redeeming every pair, the JIT LP's
        // CST can never exceed deposit + fees; the rest of its exit is risky
        // one-sided inventory, not money.
        vm.startPrank(lpBen);
        (uint256 yes, uint256 no) = market.balancesOf(ROUND, lpBen);
        market.redeemSets(ROUND, yes < no ? yes : no);
        vm.stopPrank();
        assertLe(cst.balanceOf(lpBen), jitCash + jitFees, "JIT roundtrip extracted cash beyond fees");
    }

    // ------------------------------------------------------------------
    // First-depositor share inflation
    // ------------------------------------------------------------------

    /// The classic ERC4626/Uniswap-v2 inflation attack, adapted: attacker
    /// opens the pool with the minimum, pumps reserves-per-share with huge
    /// bets, and waits for a victim deposit hoping rounding swallows it.
    /// Dead shares + the minimum initial deposit + pool-favoring rounding
    /// bound the victim's loss to dust.
    function test_attack_shareInflationYieldsOnlyDust() public {
        address attacker = bob;
        address victim = lpBen;

        // Attacker opens the pool with the bare minimum...
        vm.prank(attacker);
        uint256 attackerShares = market.addLiquidity(ROUND, 1e15, FEE, 5_000, 0, NO_DEADLINE);
        // ...and pumps reserves-per-share with a massive bet.
        vm.prank(attacker);
        market.betYes(ROUND, 1_000_000e18, 0, NO_DEADLINE);

        uint256 attackerClaimBefore = _lpClaimValueCeiling(attacker);

        // Victim deposits normally.
        uint256 victimCash = cst.balanceOf(victim);
        vm.prank(victim);
        uint256 victimShares = market.addLiquidity(ROUND, 10_000e18, FEE, 0, 0, NO_DEADLINE);
        assertGt(victimShares, 0, "victim must always receive shares");

        // Victim exits immediately; their loss is rounding dust, not capital.
        vm.startPrank(victim);
        market.removeLiquidity(ROUND, victimShares, 0, 0, NO_DEADLINE);
        (uint256 yes, uint256 no) = market.balancesOf(ROUND, victim);
        market.redeemSets(ROUND, yes < no ? yes : no);
        vm.stopPrank();
        (uint256 yesLeft, uint256 noLeft) = market.balancesOf(ROUND, victim);
        // Value the leftover single-sided tokens at zero — the harshest
        // possible accounting for the victim — and the loss is still dust.
        uint256 harshLoss = victimCash - cst.balanceOf(victim) - (yesLeft < noLeft ? yesLeft : noLeft);
        assertLt(harshLoss, 1e13, "victim lost more than dust to the inflation attack");

        // And the attacker gained nothing from the victim's roundtrip.
        assertLe(
            _lpClaimValueCeiling(attacker), attackerClaimBefore + 1e13, "attacker profited from the victim's deposit"
        );
        assertGt(attackerShares, 0);
    }

    /// @dev Upper bound on an LP's instantly-claimable value: pro-rata
    /// reserves (valuing every token at its 1 CST ceiling) plus pending fees.
    function _lpClaimValueCeiling(address who) internal view returns (uint256) {
        (uint256 shares, uint256 pending,) = market.lpPositionOf(ROUND, who);
        (uint256 rY, uint256 rN, uint256 total,,,,) = market.pool(ROUND);
        if (total == 0) return pending;
        return pending + (rY * shares / total) + (rN * shares / total);
    }

    // ------------------------------------------------------------------
    // Donations
    // ------------------------------------------------------------------

    /// Reserves are internal accounting: direct CST transfers change no
    /// quote, no share value, no fee, no payout — the donation is stranded.
    function testFuzz_attack_directDonationIsInert(uint256 donation, bool yesWins) public {
        donation = bound(donation, 1, 1e24);
        _seedPool(LIQ);
        vm.prank(alice);
        market.betYes(ROUND, 2_000e18, 0, NO_DEADLINE);

        uint256 quoteBefore = market.quoteBetNo(ROUND, 500e18);
        (uint256 rYBefore, uint256 rNBefore) = _reserves(ROUND);
        uint256 feeBefore = market.currentFeeBps(ROUND);

        cst.mint(address(market), donation); // hostile/accidental donation

        (uint256 rY, uint256 rN) = _reserves(ROUND);
        assertEq(rY, rYBefore, "donation moved reserves");
        assertEq(rN, rNBefore);
        assertEq(market.currentFeeBps(ROUND), feeBefore, "donation moved the fee");
        assertEq(market.quoteBetNo(ROUND, 500e18), quoteBefore, "donation moved quotes");

        _endRoundWith(yesWins ? THRESHOLD + 1 : THRESHOLD);
        market.resolve(ROUND);

        (uint256 yes, uint256 no) = market.balancesOf(ROUND, alice);
        vm.prank(alice);
        assertEq(market.claim(ROUND), yesWins ? yes : no, "donation changed a payout");
        assertGe(cst.balanceOf(address(market)), donation, "someone extracted the donation");
    }

    // ------------------------------------------------------------------
    // Reentrancy
    // ------------------------------------------------------------------

    /// @dev Builds a series market whose CST notifies recipients mid-transfer,
    /// simulating an ERC-777-style callback token.
    function _deployReenteringMarket() internal returns (GestureSeriesMarket m, ReenteringCst evilCst) {
        evilCst = new ReenteringCst();
        MockGame evilGame = new MockGame(address(evilCst));
        evilGame.setRoundNum(ROUND);
        evilGame.setNumBids(ROUND - 1, THRESHOLD);
        m = new GestureSeriesMarket(ICosmicSignatureGame(address(evilGame)));
        game = evilGame; // so the base helpers keep working
    }

    function test_attack_claimReentrancyBlocked() public {
        (GestureSeriesMarket m, ReenteringCst evilCst) = _deployReenteringMarket();

        ClaimReenterer attacker = new ClaimReenterer(m, ROUND);
        evilCst.mint(address(this), LIQ);
        evilCst.approve(address(m), type(uint256).max);
        m.addLiquidity(ROUND, LIQ, FEE, 5_000, 0, NO_DEADLINE);

        evilCst.mint(address(attacker), 1_000e18);
        vm.startPrank(address(attacker));
        evilCst.approve(address(m), type(uint256).max);
        m.betYes(ROUND, 1_000e18, 0, NO_DEADLINE);
        vm.stopPrank();
        (uint256 entitled,) = m.balancesOf(ROUND, address(attacker));

        game.setNumBids(ROUND, THRESHOLD + 1);
        game.setRoundNum(ROUND + 1);
        m.resolve(ROUND);

        evilCst.setHook(address(attacker));
        uint256 firstPayout = attacker.claimOnce();

        assertEq(firstPayout, entitled, "legitimate claim must pay in full");
        assertTrue(attacker.reentryReverted(), "reentrant claim must revert (lock held)");
        assertEq(evilCst.balanceOf(address(attacker)), entitled, "attacker extracted extra CST");
    }

    function test_attack_lpFeeReentrancyBlocked() public {
        (GestureSeriesMarket m, ReenteringCst evilCst) = _deployReenteringMarket();

        LpReenterer attacker = new LpReenterer(m, ROUND);
        evilCst.mint(address(attacker), LIQ);
        vm.prank(address(attacker));
        evilCst.approve(address(m), type(uint256).max);
        attacker.addLiquidity(LIQ);

        // Generate fees for the attacker-LP.
        evilCst.mint(alice, 5_000e18);
        vm.startPrank(alice);
        evilCst.approve(address(m), type(uint256).max);
        m.betYes(ROUND, 5_000e18, 0, NO_DEADLINE);
        vm.stopPrank();

        evilCst.setHook(address(attacker));
        (, uint256 pending,) = m.lpPositionOf(ROUND, address(attacker));
        uint256 got = attacker.claimFeesOnce();

        assertEq(got, pending, "legitimate fee claim pays in full");
        assertTrue(attacker.feeReentryReverted(), "reentrant claimFees must revert");
        assertTrue(attacker.removeReentryReverted(), "reentrant removeLiquidity must revert");
        assertEq(evilCst.balanceOf(address(attacker)), pending, "fees double-collected");
    }

    // ------------------------------------------------------------------
    // Misbehaving tokens
    // ------------------------------------------------------------------

    /// A token returning false (instead of reverting) must surface as
    /// TransferFailed everywhere, never as silent success.
    function test_attack_falseReturningTokenRejectedEverywhere() public {
        FalseReturningCst badCst = new FalseReturningCst();
        MockGame badGame = new MockGame(address(badCst));
        badGame.setRoundNum(ROUND);
        badGame.setNumBids(ROUND - 1, THRESHOLD);
        GestureSeriesMarket m = new GestureSeriesMarket(ICosmicSignatureGame(address(badGame)));

        badCst.mint(alice, 100_000e18);
        vm.startPrank(alice);
        badCst.approve(address(m), type(uint256).max);

        badCst.setFailTransfers(true);
        vm.expectRevert(GestureSeriesMarket.TransferFailed.selector);
        m.addLiquidity(ROUND, LIQ, FEE, 5_000, 0, NO_DEADLINE);

        badCst.setFailTransfers(false);
        m.addLiquidity(ROUND, LIQ, FEE, 5_000, 0, NO_DEADLINE);
        m.mintSets(ROUND, 100e18);

        badCst.setFailTransfers(true);
        vm.expectRevert(GestureSeriesMarket.TransferFailed.selector);
        m.betYes(ROUND, 10e18, 0, NO_DEADLINE);
        vm.expectRevert(GestureSeriesMarket.TransferFailed.selector);
        m.redeemSets(ROUND, 100e18);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Trading on known outcomes
    // ------------------------------------------------------------------

    /// Nobody can buy certainty at a discount: the atomic decided-outcome
    /// check blocks bets in the very same block the count crosses.
    function test_attack_cannotBuyDecidedOutcome() public {
        _seedPool(LIQ);

        // The pool still prices YES around 50% — a certain 2x if tradable.
        game.setNumBids(ROUND, THRESHOLD + 1);
        assertApproxEqAbs(_probBps(ROUND), 5_000, 100, "pool is stale-priced, tempting to pick off");

        vm.startPrank(alice);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.betYes(ROUND, 10_000e18, 0, NO_DEADLINE);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.betNo(ROUND, 10_000e18, 0, NO_DEADLINE);
        vm.stopPrank();

        // Minting sets on a decided round is value-neutral and stays allowed:
        // a set costs 1 CST and pays exactly 1 CST after resolution.
        vm.prank(alice);
        market.mintSets(ROUND, 100e18);
        market.resolve(ROUND);
        vm.prank(alice);
        assertEq(market.claim(ROUND), 100e18, "a set is worth exactly its cost");
    }

    /// Same protection at the round boundary: once the game advances, stale
    /// bets on the finished round revert — no betting on published results.
    function test_attack_cannotBetOnFinishedRound() public {
        _seedPool(LIQ);
        _endRoundWith(THRESHOLD + 999); // outcome public now

        vm.prank(alice);
        vm.expectRevert(GestureSeriesMarket.RoundNotActive.selector);
        market.betYes(ROUND, 1_000e18, 0, NO_DEADLINE);
    }

    /// LP funds are never trapped by resolution timing games: exits work
    /// while decided-but-unresolved AND after resolution.
    function test_lpCanAlwaysExit() public {
        uint256 shares = _seedPool(LIQ);
        vm.prank(alice);
        market.betYes(ROUND, 1_000e18, 0, NO_DEADLINE);

        _crossThreshold(); // decided, not yet resolved
        vm.prank(lpAda);
        market.removeLiquidity(ROUND, shares / 3, 0, 0, NO_DEADLINE);

        market.resolve(ROUND); // resolved
        vm.prank(lpAda);
        market.removeLiquidity(ROUND, shares / 3, 0, 0, NO_DEADLINE);
        vm.prank(lpAda);
        market.claimFees(ROUND);

        game.setRoundNum(ROUND + 5); // long over
        uint256 rest = _lpShares(ROUND, lpAda);
        vm.prank(lpAda);
        market.removeLiquidity(ROUND, rest, 0, 0, NO_DEADLINE);
        vm.prank(lpAda);
        market.claim(ROUND);
    }

    // ------------------------------------------------------------------
    // Cross-round isolation & resolution griefing
    // ------------------------------------------------------------------

    /// Activity in one round can never bleed into another: pools, balances,
    /// fees and fee votes are fully keyed by round.
    function test_attack_roundsAreFullyIsolated() public {
        _seedPool(LIQ);
        vm.prank(alice);
        market.betYes(ROUND, 2_000e18, 0, NO_DEADLINE);
        (uint256 rYBefore, uint256 rNBefore) = _reserves(ROUND);

        _endRoundWith(THRESHOLD + 1);
        market.resolve(ROUND);

        // New round: fresh pool, fresh fee vote.
        game.setNumBids(ROUND, THRESHOLD + 500);
        vm.prank(lpBen);
        market.addLiquidity(ROUND + 1, LIQ / 2, 900, 2_500, 0, NO_DEADLINE);
        vm.prank(bob);
        market.betNo(ROUND + 1, 3_000e18, 0, NO_DEADLINE);

        (uint256 rY, uint256 rN) = _reserves(ROUND);
        assertEq(rY, rYBefore, "old round reserves touched by new round");
        assertEq(rN, rNBefore);
        assertEq(market.currentFeeBps(ROUND), FEE, "old round's fee vote touched");
        assertEq(market.currentFeeBps(ROUND + 1), 900, "new round's own fee vote");

        assertGt(_lpPending(ROUND, lpAda), 0, "old-round fees preserved");
        (, uint256 adaFeesNew,) = market.lpPositionOf(ROUND + 1, lpAda);
        assertEq(adaFeesNew, 0, "no phantom fees in the new round");

        // Old-round claims unaffected by new-round activity.
        (uint256 aliceYes,) = market.balancesOf(ROUND, alice);
        vm.prank(alice);
        assertEq(market.claim(ROUND), aliceYes);
    }

    /// Resolution is permissionless but not abusable: it moves no funds and
    /// double-resolution reverts, so griefers gain nothing by racing it.
    function test_attack_resolveGriefingIsHarmless() public {
        _seedPool(LIQ);
        vm.prank(alice);
        market.betYes(ROUND, 1_000e18, 0, NO_DEADLINE);
        _endRoundWith(THRESHOLD + 1);

        uint256 balBefore = cst.balanceOf(address(market));
        vm.prank(carol); // random stranger resolves
        market.resolve(ROUND);
        assertEq(cst.balanceOf(address(market)), balBefore, "resolve must move no funds");

        vm.prank(bob);
        vm.expectRevert(GestureSeriesMarket.AlreadyResolved.selector);
        market.resolve(ROUND);
    }
}

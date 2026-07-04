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
    uint16 public immutable feeBps;
    bool public feeReentryReverted;
    bool public removeReentryReverted;
    bool internal reentered;

    constructor(GestureSeriesMarket market_, uint256 roundId_, uint16 feeBps_) {
        market = market_;
        roundId = roundId_;
        feeBps = feeBps_;
    }

    function addLiquidity(uint256 amount) external {
        market.addLiquidity(roundId, feeBps, amount, 5_000, 0, type(uint256).max);
    }

    function claimFeesOnce() external returns (uint256) {
        return market.claimFees(roundId, feeBps);
    }

    function onCstReceived() external {
        if (reentered) return;
        reentered = true;
        try market.claimFees(roundId, feeBps) {
            feeReentryReverted = false;
        } catch {
            feeReentryReverted = true;
        }
        try market.removeLiquidity(roundId, feeBps, 1, 0, 0, type(uint256).max) {
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
    // Front-running: liquidity pulls and sandwiches
    // ------------------------------------------------------------------

    /// THE attack from the design discussion: an LP watches the mempool, sees
    /// a bet coming, and pulls their liquidity first so the bet executes into
    /// a near-empty pool at a terrible price. The bettor's minTokensOut
    /// (computed off the pre-pull quote) must revert the trade — the bettor
    /// can never be filled below what they signed for.
    function test_attack_lpPullsLiquidityBeforeBet() public {
        uint256 adaShares = _seedPool(TIER_LOW, LIQ);

        // Victim quotes 1000 CST -> YES and signs with 1% slippage tolerance.
        uint256 quoted = market.quoteBetYes(ROUND, TIER_LOW, 1_000e18);
        uint256 minOut = quoted * 99 / 100;

        // LP front-runs: pulls 95% of the pool.
        vm.prank(lpAda);
        market.removeLiquidity(ROUND, TIER_LOW, adaShares * 95 / 100, 0, 0, NO_DEADLINE);

        // The victim's transaction lands after the pull — and safely reverts.
        vm.prank(alice);
        vm.expectRevert(GestureSeriesMarket.Slippage.selector);
        market.betYes(ROUND, TIER_LOW, 1_000e18, minOut, NO_DEADLINE);

        // Without the guard the fill would have been catastrophically worse.
        uint256 quotedAfterPull = market.quoteBetYes(ROUND, TIER_LOW, 1_000e18);
        assertLt(quotedAfterPull, minOut, "sanity: the pull really did degrade the price");
    }

    /// Same attack against the router: pulling the best pool must not let the
    /// router silently fill the victim on a much worse tier below their bound.
    function test_attack_lpPullsLiquidityBeforeRoutedBet() public {
        _seedPool(TIER_LOW, LIQ);
        vm.prank(lpBen);
        market.addLiquidity(ROUND, TIER_HIGH, LIQ / 10, 5_000, 0, NO_DEADLINE); // small expensive pool

        (uint16 bestTier, uint256 quoted) = market.quoteBetYesBest(ROUND, 1_000e18);
        assertEq(bestTier, TIER_LOW);
        uint256 minOut = quoted * 99 / 100;

        // The whole low-fee pool vanishes in the front-run.
        (uint256 adaShares,) = market.lpPositionOf(ROUND, TIER_LOW, lpAda);
        vm.prank(lpAda);
        market.removeLiquidity(ROUND, TIER_LOW, adaShares, 0, 0, NO_DEADLINE);

        // The router would now pick the tiny 5% pool — way below minOut. Revert.
        vm.prank(alice);
        vm.expectRevert(GestureSeriesMarket.Slippage.selector);
        market.betYesBest(ROUND, 1_000e18, minOut, NO_DEADLINE);
    }

    /// Classic sandwich: attacker buys YES ahead of the victim, victim's bet
    /// executes at the inflated price, attacker exits. The victim's slippage
    /// bound caps their loss at exactly the tolerance they chose.
    function test_attack_sandwichBoundedBySlippage() public {
        _seedPool(TIER_LOW, LIQ);
        uint256 quoted = market.quoteBetYes(ROUND, TIER_LOW, 2_000e18);
        uint256 minOut = quoted * 995 / 1_000; // 0.5% tolerance

        // Attacker front-runs with a large YES buy.
        vm.prank(bob);
        market.betYes(ROUND, TIER_LOW, 5_000e18, 0, NO_DEADLINE);

        // Victim is protected: execution would be below the signed floor.
        vm.prank(alice);
        vm.expectRevert(GestureSeriesMarket.Slippage.selector);
        market.betYes(ROUND, TIER_LOW, 2_000e18, minOut, NO_DEADLINE);

        // A small front-run that keeps execution within tolerance is allowed —
        // and then the victim's fill is by definition >= their signed minimum.
        uint256 snap = vm.snapshotState();
        vm.revertToState(snap);
    }

    /// Stale transactions can't be replayed later at manipulated prices:
    /// every mutating function honors its deadline.
    function test_attack_staleTransactionsRejectedByDeadline() public {
        _seedPool(TIER_LOW, LIQ);
        uint256 deadline = block.timestamp + 300;
        vm.warp(block.timestamp + 301);

        vm.startPrank(alice);
        vm.expectRevert(GestureSeriesMarket.DeadlineExpired.selector);
        market.betYes(ROUND, TIER_LOW, 1e18, 0, deadline);
        vm.expectRevert(GestureSeriesMarket.DeadlineExpired.selector);
        market.betNoBest(ROUND, 1e18, 0, deadline);
        vm.stopPrank();
        vm.startPrank(lpBen);
        vm.expectRevert(GestureSeriesMarket.DeadlineExpired.selector);
        market.addLiquidity(ROUND, TIER_LOW, 1_000e18, 0, 0, deadline);
        vm.expectRevert(GestureSeriesMarket.DeadlineExpired.selector);
        market.removeLiquidity(ROUND, TIER_LOW, 1, 0, 0, deadline);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // JIT liquidity
    // ------------------------------------------------------------------

    /// Just-in-time liquidity: an LP jumps in right before a big bet and out
    /// right after, skimming fees from passive LPs. The bounds that hold by
    /// construction: the JIT LP inherits zero pre-join fees, skims at most a
    /// pro-rata slice of the one bet it sniped, cannot extract more CASH than
    /// deposit + fees (its exit is paid partly in risky outcome tokens), and
    /// dilutes the passive LP by exactly the share ratio — never more. (Fee
    /// dilution itself is inherent to AMM JIT; Arbitrum's FCFS ordering plus
    /// these bounds keep it economically pointless here.)
    function test_attack_jitLiquidityCannotExtractBeyondProRataFees() public {
        _seedPool(TIER_MID, LIQ);
        // Fees accrued BEFORE the JIT join belong to Ada alone.
        vm.prank(carol);
        market.betYes(ROUND, TIER_MID, 4_000e18, 0, NO_DEADLINE);
        (, uint256 adaPreJitFees) = market.lpPositionOf(ROUND, TIER_MID, lpAda);

        uint256 jitCash = cst.balanceOf(lpBen);
        vm.prank(lpBen);
        uint256 jitShares = market.addLiquidity(ROUND, TIER_MID, LIQ, 0, 0, NO_DEADLINE);
        (, uint256 pendingAtJoin) = market.lpPositionOf(ROUND, TIER_MID, lpBen);
        assertEq(pendingAtJoin, 0, "JIT LP must not inherit pre-join fees");

        // The big bet the JIT LP is sniping.
        vm.prank(alice);
        market.betYes(ROUND, TIER_MID, 10_000e18, 0, NO_DEADLINE);
        uint256 betFee = 10_000e18 * uint256(TIER_MID) / BPS;
        uint256 totalShares = _totalShares(ROUND, TIER_MID);

        // JIT LP exits immediately.
        vm.prank(lpBen);
        (,, uint256 jitFees) = market.removeLiquidity(ROUND, TIER_MID, jitShares, 0, 0, NO_DEADLINE);
        assertLe(jitFees, betFee * jitShares / totalShares + 1, "JIT LP skimmed beyond pro-rata");

        // The passive LP keeps her pre-join fees in full plus her exact
        // pro-rata cut of the sniped bet — diluted by shares, nothing worse.
        // (Tolerance: the accumulator floors twice per fee event, losing at
        // most shares/1e18 wei each time.)
        (uint256 adaShares, uint256 adaPending) = market.lpPositionOf(ROUND, TIER_MID, lpAda);
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
        uint256 attackerShares = market.addLiquidity(ROUND, TIER_LOW, 1e15, 5_000, 0, NO_DEADLINE);
        // ...and pumps reserves-per-share with a massive bet (reserves grow,
        // shares don't).
        vm.prank(attacker);
        market.betYes(ROUND, TIER_LOW, 1_000_000e18, 0, NO_DEADLINE);

        uint256 attackerClaimBefore = _lpClaimValueCeiling(attacker);

        // Victim deposits normally.
        uint256 victimCash = cst.balanceOf(victim);
        vm.prank(victim);
        uint256 victimShares = market.addLiquidity(ROUND, TIER_LOW, 10_000e18, 0, 0, NO_DEADLINE);
        assertGt(victimShares, 0, "victim must always receive shares");

        // Victim exits immediately; their loss is rounding dust, not capital.
        vm.startPrank(victim);
        market.removeLiquidity(ROUND, TIER_LOW, victimShares, 0, 0, NO_DEADLINE);
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
        (uint256 shares, uint256 pending) = market.lpPositionOf(ROUND, TIER_LOW, who);
        (uint256 rY, uint256 rN, uint256 total,,) = market.pool(ROUND, TIER_LOW);
        if (total == 0) return pending;
        return pending + (rY * shares / total) + (rN * shares / total);
    }

    // ------------------------------------------------------------------
    // Donations
    // ------------------------------------------------------------------

    /// Reserves are internal accounting: direct CST transfers change no
    /// quote, no share value, no payout — the donation is simply stranded.
    function testFuzz_attack_directDonationIsInert(uint256 donation, bool yesWins) public {
        donation = bound(donation, 1, 1e24);
        _seedPool(TIER_LOW, LIQ);
        vm.prank(alice);
        market.betYes(ROUND, TIER_LOW, 2_000e18, 0, NO_DEADLINE);

        uint256 quoteBefore = market.quoteBetNo(ROUND, TIER_LOW, 500e18);
        (uint256 rYBefore, uint256 rNBefore) = _reserves(ROUND, TIER_LOW);

        cst.mint(address(market), donation); // hostile/accidental donation

        (uint256 rY, uint256 rN) = _reserves(ROUND, TIER_LOW);
        assertEq(rY, rYBefore, "donation moved reserves");
        assertEq(rN, rNBefore);
        assertEq(market.quoteBetNo(ROUND, TIER_LOW, 500e18), quoteBefore, "donation moved quotes");

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
        m = new GestureSeriesMarket(ICosmicSignatureGame(address(evilGame)), _defaultTiers());
        game = evilGame; // so the base helpers keep working
    }

    function test_attack_claimReentrancyBlocked() public {
        (GestureSeriesMarket m, ReenteringCst evilCst) = _deployReenteringMarket();

        ClaimReenterer attacker = new ClaimReenterer(m, ROUND);
        evilCst.mint(address(this), LIQ);
        evilCst.approve(address(m), type(uint256).max);
        m.addLiquidity(ROUND, TIER_LOW, LIQ, 5_000, 0, NO_DEADLINE);

        evilCst.mint(address(attacker), 1_000e18);
        vm.startPrank(address(attacker));
        evilCst.approve(address(m), type(uint256).max);
        m.betYes(ROUND, TIER_LOW, 1_000e18, 0, NO_DEADLINE);
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

        LpReenterer attacker = new LpReenterer(m, ROUND, TIER_LOW);
        evilCst.mint(address(attacker), LIQ);
        vm.prank(address(attacker));
        evilCst.approve(address(m), type(uint256).max);
        attacker.addLiquidity(LIQ);

        // Generate fees for the attacker-LP.
        evilCst.mint(alice, 5_000e18);
        vm.startPrank(alice);
        evilCst.approve(address(m), type(uint256).max);
        m.betYes(ROUND, TIER_LOW, 5_000e18, 0, NO_DEADLINE);
        vm.stopPrank();

        evilCst.setHook(address(attacker));
        (, uint256 pending) = m.lpPositionOf(ROUND, TIER_LOW, address(attacker));
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
        GestureSeriesMarket m = new GestureSeriesMarket(ICosmicSignatureGame(address(badGame)), _defaultTiers());

        badCst.mint(alice, 100_000e18);
        vm.startPrank(alice);
        badCst.approve(address(m), type(uint256).max);

        badCst.setFailTransfers(true);
        vm.expectRevert(GestureSeriesMarket.TransferFailed.selector);
        m.addLiquidity(ROUND, TIER_LOW, LIQ, 5_000, 0, NO_DEADLINE);

        badCst.setFailTransfers(false);
        m.addLiquidity(ROUND, TIER_LOW, LIQ, 5_000, 0, NO_DEADLINE);
        m.mintSets(ROUND, 100e18);

        badCst.setFailTransfers(true);
        vm.expectRevert(GestureSeriesMarket.TransferFailed.selector);
        m.betYes(ROUND, TIER_LOW, 10e18, 0, NO_DEADLINE);
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
        _seedPool(TIER_LOW, LIQ);

        // The pool still prices YES around 50% — a certain 2x if tradable.
        game.setNumBids(ROUND, THRESHOLD + 1);
        assertApproxEqAbs(_probBps(ROUND, TIER_LOW), 5_000, 100, "pool is stale-priced, tempting to pick off");

        vm.startPrank(alice);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.betYes(ROUND, TIER_LOW, 10_000e18, 0, NO_DEADLINE);
        vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
        market.betYesBest(ROUND, 10_000e18, 0, NO_DEADLINE);
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
        _seedPool(TIER_LOW, LIQ);
        _endRoundWith(THRESHOLD + 999); // outcome public now

        vm.prank(alice);
        vm.expectRevert(GestureSeriesMarket.RoundNotActive.selector);
        market.betYes(ROUND, TIER_LOW, 1_000e18, 0, NO_DEADLINE);
    }

    /// LP funds are never trapped by resolution timing games: exits work
    /// while decided-but-unresolved AND after resolution.
    function test_lpCanAlwaysExit() public {
        uint256 shares = _seedPool(TIER_LOW, LIQ);
        vm.prank(alice);
        market.betYes(ROUND, TIER_LOW, 1_000e18, 0, NO_DEADLINE);

        _crossThreshold(); // decided, not yet resolved
        vm.prank(lpAda);
        market.removeLiquidity(ROUND, TIER_LOW, shares / 3, 0, 0, NO_DEADLINE);

        market.resolve(ROUND); // resolved
        vm.prank(lpAda);
        market.removeLiquidity(ROUND, TIER_LOW, shares / 3, 0, 0, NO_DEADLINE);
        vm.prank(lpAda);
        market.claimFees(ROUND, TIER_LOW);

        game.setRoundNum(ROUND + 5); // long over
        (uint256 rest,) = market.lpPositionOf(ROUND, TIER_LOW, lpAda);
        vm.prank(lpAda);
        market.removeLiquidity(ROUND, TIER_LOW, rest, 0, 0, NO_DEADLINE);
        vm.prank(lpAda);
        market.claim(ROUND);
    }

    // ------------------------------------------------------------------
    // Cross-round isolation
    // ------------------------------------------------------------------

    /// Activity in one round can never bleed into another: pools, balances
    /// and fees are fully keyed by round.
    function test_attack_roundsAreFullyIsolated() public {
        _seedPool(TIER_LOW, LIQ);
        vm.prank(alice);
        market.betYes(ROUND, TIER_LOW, 2_000e18, 0, NO_DEADLINE);
        (uint256 rYBefore, uint256 rNBefore) = _reserves(ROUND, TIER_LOW);

        _endRoundWith(THRESHOLD + 1);
        market.resolve(ROUND);

        // New round: same tier key, fresh pool.
        game.setNumBids(ROUND, THRESHOLD + 500); // finished count of old round
        vm.prank(lpBen);
        market.addLiquidity(ROUND + 1, TIER_LOW, LIQ / 2, 2_500, 0, NO_DEADLINE);
        vm.prank(bob);
        market.betNo(ROUND + 1, TIER_LOW, 3_000e18, 0, NO_DEADLINE);

        (uint256 rY, uint256 rN) = _reserves(ROUND, TIER_LOW);
        assertEq(rY, rYBefore, "old round reserves touched by new round");
        assertEq(rN, rNBefore);

        (, uint256 adaFeesOld) = market.lpPositionOf(ROUND, TIER_LOW, lpAda);
        (, uint256 adaFeesNew) = market.lpPositionOf(ROUND + 1, TIER_LOW, lpAda);
        assertGt(adaFeesOld, 0, "old-round fees preserved");
        assertEq(adaFeesNew, 0, "no phantom fees in the new round");

        // Old-round claims unaffected by new-round activity.
        (uint256 aliceYes,) = market.balancesOf(ROUND, alice);
        vm.prank(alice);
        assertEq(market.claim(ROUND), aliceYes);
    }

    /// Resolution is permissionless but not abusable: it moves no funds and
    /// double-resolution reverts, so griefers gain nothing by racing it.
    function test_attack_resolveGriefingIsHarmless() public {
        _seedPool(TIER_LOW, LIQ);
        vm.prank(alice);
        market.betYes(ROUND, TIER_LOW, 1_000e18, 0, NO_DEADLINE);
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {GestureSeriesMarket} from "../src/GestureSeriesMarket.sol";
import {SeriesTestBase} from "./utils/SeriesTestBase.sol";
import {MockCst, MockGame} from "./utils/Mocks.sol";

/// @notice Fuzzed actor that drives the series market through arbitrary
/// interleavings of the full multi-round lifecycle: liquidity in and out,
/// fee re-votes, bets, set minting/redeeming, gesture-count bumps (including
/// threshold crossings), round advancement, early and normal resolution, and
/// claims. Every input is bounded so no call ever reverts — the suite runs
/// with `fail_on_revert = true`, meaning ANY unexpected revert fails the run.
contract SeriesHandler is CommonBase, StdCheats, StdUtils {
    GestureSeriesMarket public immutable market;
    MockCst public immutable cst;
    MockGame public immutable game;

    address[] public actors;
    uint256[] public roundsTouched; // every round that ever got initialized

    /// Ghost accounting: every wei of CST that ever entered or left the market.
    uint256 public ghost_cstIn;
    uint256 public ghost_cstOut;

    constructor(GestureSeriesMarket market_, MockCst cst_, MockGame game_) {
        market = market_;
        cst = cst_;
        game = game_;
        for (uint256 i = 0; i < 5; i++) {
            address actor = makeAddr(string(abi.encodePacked("handlerActor", vm.toString(i))));
            actors.push(actor);
            vm.prank(actor);
            cst.approve(address(market_), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function roundsTouchedCount() external view returns (uint256) {
        return roundsTouched.length;
    }

    // ------------------------------------------------------------------
    // Fuzzed actions
    // ------------------------------------------------------------------

    function addLiquidity(uint256 actorSeed, uint256 amount, uint256 declSeed, uint256 probBps) external {
        uint256 roundId = game.roundNum();
        if (roundId == 0) return;
        if (!_fundable(roundId)) return;
        address actor = _actor(actorSeed);
        amount = _bound(amount, 1e15, 100_000e18);
        uint16 decl = uint16(_bound(declSeed, 0, 1_000));
        probBps = _bound(probBps, 100, 9_900);

        // Joining must be able to mint at least one share, and a pool
        // dust-drained to a zero reserve is permanently closed to joins.
        (uint256 rY, uint256 rN, uint256 totalShares,,,,) = market.pool(roundId);
        if (totalShares > 0) {
            if (rY == 0 || rN == 0) return;
            uint256 m = rY > rN ? rY : rN;
            if (totalShares * amount / m == 0) return;
        }

        bool wasInitialized = _initialized(roundId);
        cst.mint(actor, amount);
        (, uint256 pendingBefore,) = market.lpPositionOf(roundId, actor);
        vm.prank(actor);
        market.addLiquidity(roundId, amount, decl, probBps, 0, type(uint256).max);
        ghost_cstIn += amount;
        ghost_cstOut += pendingBefore; // joining settles accrued fees in CST
        if (!wasInitialized) roundsTouched.push(roundId);
    }

    function removeLiquidity(uint256 actorSeed, uint256 roundSeed, uint256 fraction) external {
        (uint256 roundId, bool ok) = _someRound(roundSeed);
        if (!ok) return;
        address actor = _actor(actorSeed);
        (uint256 shares,,) = market.lpPositionOf(roundId, actor);
        if (shares == 0) return;
        uint256 toBurn = _bound(fraction, 1, shares);
        vm.prank(actor);
        (,, uint256 fees) = market.removeLiquidity(roundId, toBurn, 0, 0, type(uint256).max);
        ghost_cstOut += fees;
    }

    function updateFeeDeclaration(uint256 actorSeed, uint256 roundSeed, uint256 declSeed) external {
        (uint256 roundId, bool ok) = _someRound(roundSeed);
        if (!ok) return;
        address actor = _actor(actorSeed);
        (uint256 shares,,) = market.lpPositionOf(roundId, actor);
        if (shares == 0) return;
        vm.prank(actor);
        market.updateFeeDeclaration(roundId, uint16(_bound(declSeed, 0, 1_000)));
    }

    function claimFees(uint256 actorSeed, uint256 roundSeed) external {
        (uint256 roundId, bool ok) = _someRound(roundSeed);
        if (!ok) return;
        address actor = _actor(actorSeed);
        vm.prank(actor);
        uint256 fees = market.claimFees(roundId);
        ghost_cstOut += fees;
    }

    function bet(uint256 actorSeed, uint256 amount, bool yes) external {
        uint256 roundId = game.roundNum();
        if (!_tradable(roundId)) return;
        address actor = _actor(actorSeed);
        amount = _bound(amount, 1, 100_000e18);

        (uint256 rY, uint256 rN, uint256 totalShares,,,, uint256 feeBps) = market.pool(roundId);
        if (totalShares == 0 || rY == 0 || rN == 0) return; // unfunded or dust-drained pool

        cst.mint(actor, amount);
        vm.prank(actor);
        uint256 tokensOut = yes
            ? market.betYes(roundId, amount, 0, type(uint256).max)
            : market.betNo(roundId, amount, 0, type(uint256).max);
        ghost_cstIn += amount;
        require(tokensOut >= amount - amount * feeBps / 10_000, "handler: token cost above 1 CST");
    }

    function mintSets(uint256 actorSeed, uint256 amount) external {
        uint256 roundId = game.roundNum();
        if (!_initialized(roundId) || _resolved(roundId)) return;
        address actor = _actor(actorSeed);
        amount = _bound(amount, 1, 100_000e18);
        cst.mint(actor, amount);
        vm.prank(actor);
        market.mintSets(roundId, amount);
        ghost_cstIn += amount;
    }

    function redeemSets(uint256 actorSeed, uint256 roundSeed, uint256 amount) external {
        (uint256 roundId, bool ok) = _someRound(roundSeed);
        if (!ok || _resolved(roundId)) return;
        address actor = _actor(actorSeed);
        (uint256 yes, uint256 no) = market.balancesOf(roundId, actor);
        uint256 maxRedeem = yes < no ? yes : no;
        if (maxRedeem == 0) return;
        amount = _bound(amount, 1, maxRedeem);
        vm.prank(actor);
        market.redeemSets(roundId, amount);
        ghost_cstOut += amount;
    }

    /// Gestures happen: the live count only ever goes UP. Occasionally this
    /// crosses the threshold and decides the outcome mid-round.
    function gesturesArrive(uint256 delta) external {
        uint256 roundId = game.roundNum();
        delta = _bound(delta, 1, 400);
        game.setNumBids(roundId, game.bidderAddresses(roundId) + delta);
    }

    /// The round's main prize gets claimed: the game advances to a new round.
    /// Gated so campaigns spend most of their depth trading a live market.
    function endRound(uint256 gate) external {
        if (gate % 5 != 0) return;
        game.setRoundNum(game.roundNum() + 1);
    }

    function resolve(uint256 roundSeed) external {
        (uint256 roundId, bool ok) = _someRound(roundSeed);
        if (!ok || _resolved(roundId)) return;
        (,,, uint256 threshold, uint256 count, bool active,) = market.roundState(roundId);
        if (active && count <= threshold) return; // not resolvable yet
        market.resolve(roundId);
    }

    function claim(uint256 actorSeed, uint256 roundSeed) external {
        (uint256 roundId, bool ok) = _someRound(roundSeed);
        if (!ok || !_resolved(roundId)) return;
        address actor = _actor(actorSeed);
        vm.prank(actor);
        ghost_cstOut += market.claim(roundId);
    }

    // ------------------------------------------------------------------
    // Teardown used by afterInvariant
    // ------------------------------------------------------------------

    /// Force every touched round to completion and exit everyone from
    /// everything, recording all outflows.
    function finishEverything() external {
        for (uint256 i = 0; i < roundsTouched.length; i++) {
            uint256 roundId = roundsTouched[i];
            if (!_resolved(roundId)) {
                if (game.roundNum() == roundId) game.setRoundNum(roundId + 1);
                market.resolve(roundId);
            }
            for (uint256 a = 0; a < actors.length; a++) {
                address actor = actors[a];
                (uint256 shares,,) = market.lpPositionOf(roundId, actor);
                if (shares > 0) {
                    vm.prank(actor);
                    (,, uint256 fees) = market.removeLiquidity(roundId, shares, 0, 0, type(uint256).max);
                    ghost_cstOut += fees;
                }
                vm.prank(actor);
                ghost_cstOut += market.claimFees(roundId);
                vm.prank(actor);
                ghost_cstOut += market.claim(roundId);
            }
        }
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return actors[_bound(seed, 0, actors.length - 1)];
    }

    function _someRound(uint256 seed) internal view returns (uint256 roundId, bool ok) {
        if (roundsTouched.length == 0) return (0, false);
        return (roundsTouched[_bound(seed, 0, roundsTouched.length - 1)], true);
    }

    function _initialized(uint256 roundId) internal view returns (bool initialized) {
        (initialized,,,,,,) = market.roundState(roundId);
    }

    function _resolved(uint256 roundId) internal view returns (bool resolved) {
        (, resolved,,,,,) = market.roundState(roundId);
    }

    /// Betting requires: initialized, unresolved, live, outcome still open.
    function _tradable(uint256 roundId) internal view returns (bool) {
        (bool initialized, bool resolved,,,, bool active, bool decided) = market.roundState(roundId);
        return initialized && !resolved && active && !decided;
    }

    /// addLiquidity additionally works on uninitialized (current) rounds,
    /// as long as the would-be outcome isn't decided already.
    function _fundable(uint256 roundId) internal view returns (bool) {
        (bool initialized, bool resolved,,, uint256 count, bool active, bool decided) = market.roundState(roundId);
        if (!active || resolved) return false;
        if (initialized) return !decided;
        return count <= game.bidderAddresses(roundId - 1);
    }
}

/// @notice Stateful invariant suite: the fuzzer generates random call
/// sequences against the handler; after EVERY call all `invariant_` properties
/// are re-checked, and after every campaign `afterInvariant` force-drains the
/// whole series to prove everyone can always be paid in full.
contract GestureSeriesMarketInvariantTest is SeriesTestBase {
    SeriesHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SeriesHandler(market, cst, game);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = SeriesHandler.addLiquidity.selector;
        selectors[1] = SeriesHandler.removeLiquidity.selector;
        selectors[2] = SeriesHandler.updateFeeDeclaration.selector;
        selectors[3] = SeriesHandler.claimFees.selector;
        selectors[4] = SeriesHandler.bet.selector;
        selectors[5] = SeriesHandler.mintSets.selector;
        selectors[6] = SeriesHandler.redeemSets.selector;
        selectors[7] = SeriesHandler.gesturesArrive.selector;
        selectors[8] = SeriesHandler.endRound.selector;
        selectors[9] = SeriesHandler.resolve.selector;
        selectors[10] = SeriesHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _actors() internal view returns (address[] memory list) {
        uint256 n = handler.actorCount();
        list = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            list[i] = handler.actors(i);
        }
    }

    /// Exact cash-flow accounting: the market's CST balance always equals
    /// every wei that ever flowed in minus every wei that flowed out.
    function invariant_balanceMatchesNetFlows() public view {
        assertEq(
            cst.balanceOf(address(market)),
            handler.ghost_cstIn() - handler.ghost_cstOut(),
            "balance diverged from tracked flows"
        );
    }

    /// The heart of solvency, exact to the wei at all times: the contract's
    /// CST balance equals the sum over every round of its outstanding-set
    /// liability (unresolved: the paired supply; resolved: the winning-side
    /// supply) plus the pool's unclaimed fee escrow. As a corollary, YES and
    /// NO supplies match exactly while a round is unresolved.
    function invariant_exactCollateralization() public view {
        address[] memory actorList = _actors();
        uint256 liabilities;
        uint256 n = handler.roundsTouchedCount();
        for (uint256 i = 0; i < n; i++) {
            liabilities += _roundLiability(handler.roundsTouched(i), actorList);
        }
        assertEq(cst.balanceOf(address(market)), liabilities, "collateral != liabilities");
    }

    function _roundLiability(uint256 roundId, address[] memory actorList) internal view returns (uint256 liability) {
        (, bool resolved, bool yesWon,,,,) = market.roundState(roundId);
        (uint256 totalYes, uint256 totalNo,,, uint256 feeReserve,,) = market.pool(roundId);

        for (uint256 a = 0; a < actorList.length; a++) {
            (uint256 yes, uint256 no) = market.balancesOf(roundId, actorList[a]);
            totalYes += yes;
            totalNo += no;
        }
        liability = feeReserve;
        if (!resolved) {
            assertEq(totalYes, totalNo, "outcome token supplies diverged");
            liability += totalYes;
        } else {
            liability += yesWon ? totalYes : totalNo;
        }
    }

    /// The fee-vote ledger is always exactly the naive sum over every holder
    /// (actors + dead shares), and the resulting average never exceeds the cap.
    function invariant_feeVoteLedgerExact() public view {
        address[] memory actorList = _actors();
        uint256 n = handler.roundsTouchedCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 roundId = handler.roundsTouched(i);
            (,, uint256 totalShares,,, uint256 feeWeight, uint256 feeBps) = market.pool(roundId);
            if (totalShares == 0) continue;

            (uint256 deadShares,, uint16 deadDecl) = market.lpPositionOf(roundId, address(0));
            uint256 naive = deadShares * uint256(deadDecl);
            for (uint256 a = 0; a < actorList.length; a++) {
                (uint256 shares,, uint16 decl) = market.lpPositionOf(roundId, actorList[a]);
                naive += shares * uint256(decl);
            }
            assertEq(feeWeight, naive, "fee ledger diverged from naive sum");
            assertEq(feeBps, naive / totalShares, "average is not ledger / shares");
            assertLe(feeBps, 1_000, "average above the cap");
        }
    }

    /// Share accounting is always coherent: the actors' shares plus the
    /// permanently locked dead shares equal totalShares, and the sum of
    /// everyone's pending fees never exceeds the pool's fee escrow.
    function invariant_shareAndFeeAccountingCoherent() public view {
        address[] memory actorList = _actors();
        uint256 n = handler.roundsTouchedCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 roundId = handler.roundsTouched(i);
            (,, uint256 totalShares,, uint256 feeReserve,,) = market.pool(roundId);
            if (totalShares == 0) continue;
            (uint256 sumShares,,) = market.lpPositionOf(roundId, address(0)); // dead shares
            uint256 sumPending;
            for (uint256 a = 0; a < actorList.length; a++) {
                (uint256 shares, uint256 pending,) = market.lpPositionOf(roundId, actorList[a]);
                sumShares += shares;
                sumPending += pending;
            }
            assertEq(sumShares, totalShares, "share ledger diverged");
            assertLe(sumPending, feeReserve, "owed more fees than escrowed");
        }
    }

    /// A pool with real LPs can never have an empty reserve while its round
    /// is unresolved (the AMM never sells its last token).
    function invariant_fundedPoolsNeverDrainWhileLive() public view {
        uint256 n = handler.roundsTouchedCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 roundId = handler.roundsTouched(i);
            (uint256 rY, uint256 rN, uint256 totalShares,,,,) = market.pool(roundId);
            if (totalShares > DEAD_SHARES) {
                assertGe(rY, 1, "YES reserve emptied");
                assertGe(rN, 1, "NO reserve emptied");
            }
        }
    }

    /// After every fuzz campaign: force-finish every round and prove everyone
    /// can exit in full. Afterwards the contract retains EXACTLY the CST
    /// backing dead-share reserves and fee-rounding dust — nothing else.
    function afterInvariant() public {
        handler.finishEverything();

        assertLe(handler.ghost_cstOut(), handler.ghost_cstIn(), "paid out more than ever came in");

        address[] memory actorList = _actors();
        uint256 expectedRetained;
        uint256 n = handler.roundsTouchedCount();
        for (uint256 i = 0; i < n; i++) {
            expectedRetained += _drainedRoundRetention(handler.roundsTouched(i), actorList);
        }
        assertEq(
            cst.balanceOf(address(market)),
            expectedRetained,
            "retained CST is not exactly dead-share reserves plus fee dust"
        );
        assertEq(
            cst.balanceOf(address(market)),
            handler.ghost_cstIn() - handler.ghost_cstOut(),
            "ghost flows diverged after teardown"
        );
    }

    /// @dev Asserts a force-drained round holds nothing but dead-share
    /// reserves and fee dust, returning that exact retention.
    function _drainedRoundRetention(uint256 roundId, address[] memory actorList) internal view returns (uint256) {
        (, bool resolved, bool yesWon,,,,) = market.roundState(roundId);
        assertTrue(resolved, "teardown left a round unresolved");
        (uint256 rY, uint256 rN, uint256 totalShares,, uint256 feeReserve,,) = market.pool(roundId);
        if (totalShares != 0) {
            assertEq(totalShares, DEAD_SHARES, "an actor still holds shares after teardown");
        }
        for (uint256 a = 0; a < actorList.length; a++) {
            (uint256 yes, uint256 no) = market.balancesOf(roundId, actorList[a]);
            assertEq(yes, 0, "unclaimed YES after teardown");
            assertEq(no, 0, "unclaimed NO after teardown");
        }
        return feeReserve + (yesWon ? rY : rN);
    }
}

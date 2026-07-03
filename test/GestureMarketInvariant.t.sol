// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {GestureMarket} from "../src/GestureMarket.sol";
import {MarketTestBase} from "./utils/MarketTestBase.sol";
import {MockCst, MockGame} from "./utils/Mocks.sol";

/// @notice Fuzzed actor that drives the market through arbitrary interleavings
/// of the full lifecycle: bets, set minting/redeeming, round end, resolution,
/// and claims. Every input is bounded so no call ever reverts — the suite runs
/// with `fail_on_revert = true`, meaning ANY unexpected revert fails the run.
contract Handler is CommonBase, StdCheats, StdUtils {
    GestureMarket public immutable market;
    MockCst public immutable cst;
    MockGame public immutable game;
    address public immutable creator;

    address[] public actors;

    /// Ghost accounting: every wei of CST that ever entered or left the market.
    uint256 public ghost_cstIn;
    uint256 public ghost_cstOut;
    uint256 public ghost_lastK;

    constructor(GestureMarket market_, MockCst cst_, MockGame game_, address creator_, uint256 initialLiquidity) {
        market = market_;
        cst = cst_;
        game = game_;
        creator = creator_;
        for (uint256 i = 0; i < 5; i++) {
            address actor = makeAddr(string(abi.encodePacked("handlerActor", vm.toString(i))));
            actors.push(actor);
            vm.prank(actor);
            cst.approve(address(market_), type(uint256).max);
        }
        ghost_cstIn = initialLiquidity;
        ghost_lastK = market_.reserveHigher() * market_.reserveLower();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ------------------------------------------------------------------
    // Fuzzed actions
    // ------------------------------------------------------------------

    function betHigher(uint256 actorSeed, uint256 amount) external {
        if (!_roundActive()) return;
        address actor = _actor(actorSeed);
        amount = _bound(amount, 1, 250_000e18);
        cst.mint(actor, amount);
        vm.prank(actor);
        uint256 tokensOut = market.betHigher(amount, 0);
        ghost_cstIn += amount;
        require(tokensOut >= amount - amount * market.feeBps() / 10_000, "handler: token cost above 1 CST");
        _checkK();
    }

    function betLower(uint256 actorSeed, uint256 amount) external {
        if (!_roundActive()) return;
        address actor = _actor(actorSeed);
        amount = _bound(amount, 1, 250_000e18);
        cst.mint(actor, amount);
        vm.prank(actor);
        uint256 tokensOut = market.betLower(amount, 0);
        ghost_cstIn += amount;
        require(tokensOut >= amount - amount * market.feeBps() / 10_000, "handler: token cost above 1 CST");
        _checkK();
    }

    function mintSets(uint256 actorSeed, uint256 amount) external {
        if (!_roundActive()) return;
        address actor = _actor(actorSeed);
        amount = _bound(amount, 1, 250_000e18);
        cst.mint(actor, amount);
        vm.prank(actor);
        market.mintSets(amount);
        ghost_cstIn += amount;
    }

    function redeemSets(uint256 actorSeed, uint256 amount) external {
        if (!_roundActive()) return;
        address actor = _actor(actorSeed);
        uint256 h = market.higherBalance(actor);
        uint256 l = market.lowerBalance(actor);
        uint256 maxRedeem = h < l ? h : l;
        if (maxRedeem == 0) return;
        amount = _bound(amount, 1, maxRedeem);
        vm.prank(actor);
        market.redeemSets(amount);
        ghost_cstOut += amount;
    }

    function endRound(uint256 finalCount) external {
        if (!_roundActive()) return;
        // Fire only occasionally so campaigns spend most of their depth on a
        // live market; afterInvariant guarantees the ended phase is always
        // reached and drained at the end of every run regardless.
        if (finalCount % 8 != 0) return;
        finalCount = _bound(finalCount, 0, 5_000);
        game.setNumBids(market.round(), finalCount);
        game.setRoundNum(market.round() + 1);
    }

    function resolve() external {
        if (_roundActive() || market.resolved()) return;
        uint256 fees = market.feesAccrued();
        market.resolve();
        ghost_cstOut += fees;
    }

    function claim(uint256 actorSeed) external {
        if (!market.resolved()) return;
        uint256 idx = _bound(actorSeed, 0, actors.length); // last index = creator
        address who = idx == actors.length ? creator : actors[idx];
        vm.prank(who);
        uint256 cstOut = market.claim();
        ghost_cstOut += cstOut;
    }

    /// @dev Teardown used by afterInvariant: force the lifecycle to completion
    /// from whatever state the campaign left behind.
    function finishLifecycle() external {
        if (_roundActive()) {
            game.setNumBids(market.round(), 777);
            game.setRoundNum(market.round() + 1);
        }
        if (!market.resolved()) {
            uint256 fees = market.feesAccrued();
            market.resolve();
            ghost_cstOut += fees;
        }
        for (uint256 i = 0; i < actors.length; i++) {
            vm.prank(actors[i]);
            ghost_cstOut += market.claim();
        }
        vm.prank(creator);
        ghost_cstOut += market.claim();
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return actors[_bound(seed, 0, actors.length - 1)];
    }

    function _roundActive() internal view returns (bool) {
        return game.roundNum() == market.round();
    }

    function _checkK() internal {
        uint256 k = market.reserveHigher() * market.reserveLower();
        require(k >= ghost_lastK, "handler: constant product decreased");
        ghost_lastK = k;
    }
}

/// @notice Stateful invariant suite: the fuzzer generates random call sequences
/// against the Handler; after EVERY call, all `invariant_` properties below are
/// re-checked, and after every campaign `afterInvariant` drains the market to
/// prove everyone can always be paid.
contract GestureMarketInvariantTest is MarketTestBase {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(market, cst, game, creator, LIQ);
        targetContract(address(handler));

        // Fuzz only the lifecycle actions; finishLifecycle is reserved for the
        // afterInvariant teardown so campaigns explore long live-market histories.
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = Handler.betHigher.selector;
        selectors[1] = Handler.betLower.selector;
        selectors[2] = Handler.mintSets.selector;
        selectors[3] = Handler.redeemSets.selector;
        selectors[4] = Handler.endRound.selector;
        selectors[5] = Handler.resolve.selector;
        selectors[6] = Handler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _allHolders() internal view returns (address[] memory holders) {
        uint256 n = handler.actorCount();
        holders = new address[](n + 1);
        for (uint256 i = 0; i < n; i++) {
            holders[i] = handler.actors(i);
        }
        holders[n] = creator;
    }

    /// Exact cash-flow accounting: the market's CST balance always equals every
    /// wei that flowed in minus every wei that flowed out. No leaks, no creation.
    function invariant_balanceMatchesNetFlows() public view {
        assertEq(
            cst.balanceOf(address(market)),
            handler.ghost_cstIn() - handler.ghost_cstOut(),
            "balance diverged from tracked flows"
        );
    }

    /// Pre-resolution the market is fully collateralized: HIGHER and LOWER
    /// supplies are identical, and CST holdings equal outstanding sets + fees.
    function invariant_fullyCollateralizedPreResolution() public view {
        if (market.resolved()) return;
        uint256 totalHigher = market.reserveHigher();
        uint256 totalLower = market.reserveLower();
        address[] memory holders = _allHolders();
        for (uint256 i = 0; i < holders.length; i++) {
            totalHigher += market.higherBalance(holders[i]);
            totalLower += market.lowerBalance(holders[i]);
        }
        assertEq(totalHigher, totalLower, "outcome token supplies diverged");
        assertEq(
            cst.balanceOf(address(market)),
            totalHigher + market.feesAccrued(),
            "collateral does not match outstanding sets plus fees"
        );
    }

    /// Post-resolution the balance always covers every remaining claim in full.
    function invariant_solventPostResolution() public view {
        if (!market.resolved()) return;
        uint256 f = market.payoutPerHigher();
        uint256 owedScaled; // scaled by 1e18
        address[] memory holders = _allHolders();
        for (uint256 i = 0; i < holders.length; i++) {
            owedScaled += market.higherBalance(holders[i]) * f + market.lowerBalance(holders[i]) * (1e18 - f);
        }
        assertGe(cst.balanceOf(address(market)) * 1e18, owedScaled, "cannot cover all remaining claims");
    }

    /// The live prediction can never leave the market's range.
    function invariant_predictionWithinRange() public view {
        uint256 predicted = market.predictedCount();
        assertGe(predicted, MIN, "prediction below range");
        assertLe(predicted, MAX, "prediction above range");
    }

    /// The pool can never be drained nor lose value versus inception while live.
    function invariant_poolNeverDrainedPreResolution() public view {
        if (market.resolved()) return;
        assertGe(market.reserveHigher(), 1, "higher reserve emptied");
        assertGe(market.reserveLower(), 1, "lower reserve emptied");
        assertGe(market.reserveHigher() * market.reserveLower(), LIQ * LIQ, "k fell below inception");
    }

    /// Resolution state stays coherent no matter how it was reached.
    function invariant_resolutionStateCoherent() public view {
        if (!market.resolved()) return;
        assertEq(market.feesAccrued(), 0, "fees lingering after resolve");
        assertGt(game.roundNum(), market.round(), "resolved while round still active");
        assertEq(market.reserveHigher(), 0, "pool not liquidated at resolve");
        assertEq(market.reserveLower(), 0, "pool not liquidated at resolve");
        assertLe(market.payoutPerHigher(), 1e18, "payout fraction above 100%");
    }

    /// After every fuzz campaign: force-finish the market and prove that every
    /// participant can be paid in full, with at most integer-division dust left.
    function afterInvariant() public {
        handler.finishLifecycle();

        assertLe(handler.ghost_cstOut(), handler.ghost_cstIn(), "paid out more than ever came in");
        assertLt(cst.balanceOf(address(market)), 8, "more than dust stuck after full drain");

        address[] memory holders = _allHolders();
        for (uint256 i = 0; i < holders.length; i++) {
            assertEq(market.higherBalance(holders[i]), 0, "unclaimed HIGHER after drain");
            assertEq(market.lowerBalance(holders[i]), 0, "unclaimed LOWER after drain");
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GestureSeriesMarket} from "../../src/GestureSeriesMarket.sol";
import {ICosmicSignatureGame} from "../../src/ICosmicSignatureGame.sol";
import {MockCst, MockGame} from "./Mocks.sol";

/// @notice Shared fixture for all GestureSeriesMarket test suites: mocks, the
/// singleton series market, funded actors, and round/lifecycle helpers.
abstract contract SeriesTestBase is Test {
    uint16 internal constant FEE = 200; // the default fee declaration: 2%
    uint256 internal constant MAX_FEE_BPS = 1_000;

    uint256 internal constant ROUND = 5;
    uint256 internal constant THRESHOLD = 800; // final count of ROUND - 1
    uint256 internal constant LIQ = 10_000e18;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant DEAD_SHARES = 1e3;
    uint256 internal constant NO_DEADLINE = type(uint256).max;

    MockCst internal cst;
    MockGame internal game;
    GestureSeriesMarket internal market;

    address internal lpAda = makeAddr("lpAda");
    address internal lpBen = makeAddr("lpBen");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        cst = new MockCst();
        game = new MockGame(address(cst));
        game.setRoundNum(ROUND);
        game.setNumBids(ROUND - 1, THRESHOLD);

        market = new GestureSeriesMarket(ICosmicSignatureGame(address(game)));

        address[5] memory actors = [lpAda, lpBen, alice, bob, carol];
        for (uint256 i = 0; i < actors.length; i++) {
            cst.mint(actors[i], 10_000_000e18);
            vm.prank(actors[i]);
            cst.approve(address(market), type(uint256).max);
        }
    }

    /// @dev A memory mirror of `roundState`'s outputs, so tests read one field
    /// by name instead of destructuring an 8-tuple.
    struct RoundView {
        bool initialized;
        bool thresholdKnown;
        bool resolved;
        bool yesWon;
        uint256 threshold;
        uint256 currentCount;
        bool roundActive;
        bool outcomeDecided;
    }

    function _state(uint256 roundId) internal view returns (RoundView memory v) {
        (
            v.initialized,
            v.thresholdKnown,
            v.resolved,
            v.yesWon,
            v.threshold,
            v.currentCount,
            v.roundActive,
            v.outcomeDecided
        ) = market.roundState(roundId);
    }

    /// @dev Opens ROUND's pool with `liq` CST at 50/50 odds and a 2% fee vote,
    /// via lpAda.
    function _seedPool(uint256 liq) internal returns (uint256 shares) {
        vm.prank(lpAda);
        shares = market.addLiquidity(ROUND, liq, FEE, 5_000, 0, NO_DEADLINE);
    }

    /// @dev Opens ROUND's pool with full control over the declaration and odds.
    function _seedPoolWith(address lp, uint256 liq, uint16 feeBps, uint256 probBps) internal returns (uint256 shares) {
        vm.prank(lp);
        shares = market.addLiquidity(ROUND, liq, feeBps, probBps, 0, NO_DEADLINE);
    }

    /// @dev Opens ANY round's pool (current or future) at 50/50 odds via `lp`.
    function _seedRoundPool(uint256 roundId, address lp, uint256 liq) internal returns (uint256 shares) {
        vm.prank(lp);
        shares = market.addLiquidity(roundId, liq, FEE, 5_000, 0, NO_DEADLINE);
    }

    /// @dev Ends ROUND with the given final gesture count (advances the game).
    function _endRoundWith(uint256 finalCount) internal {
        game.setNumBids(ROUND, finalCount);
        game.setRoundNum(ROUND + 1);
    }

    /// @dev Raises the live count above the threshold, deciding the outcome early.
    function _crossThreshold() internal {
        game.setNumBids(ROUND, THRESHOLD + 1);
    }

    function _reserves(uint256 roundId) internal view returns (uint256 rY, uint256 rN) {
        (rY, rN,,,,,) = market.pool(roundId);
    }

    function _totalShares(uint256 roundId) internal view returns (uint256 shares) {
        (,, shares,,,,) = market.pool(roundId);
    }

    function _feeReserve(uint256 roundId) internal view returns (uint256 feeReserve) {
        (,,,, feeReserve,,) = market.pool(roundId);
    }

    function _feeWeight(uint256 roundId) internal view returns (uint256 feeWeight) {
        (,,,,, feeWeight,) = market.pool(roundId);
    }

    function _lpShares(uint256 roundId, address who) internal view returns (uint256 shares) {
        (shares,,) = market.lpPositionOf(roundId, who);
    }

    function _lpPending(uint256 roundId, address who) internal view returns (uint256 pending) {
        (, pending,) = market.lpPositionOf(roundId, who);
    }

    function _lpDeclaration(uint256 roundId, address who) internal view returns (uint16 declared) {
        (,, declared) = market.lpPositionOf(roundId, who);
    }

    function _yesBal(address who) internal view returns (uint256 yes) {
        (yes,) = market.balancesOf(ROUND, who);
    }

    function _noBal(address who) internal view returns (uint256 no) {
        (, no) = market.balancesOf(ROUND, who);
    }

    /// @dev The pool's implied YES probability in bps: reserveNo / (rY + rN).
    function _probBps(uint256 roundId) internal view returns (uint256) {
        (uint256 rY, uint256 rN) = _reserves(roundId);
        if (rY + rN == 0) return 0;
        return rN * BPS / (rY + rN);
    }
}

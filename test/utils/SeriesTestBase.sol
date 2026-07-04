// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GestureSeriesMarket} from "../../src/GestureSeriesMarket.sol";
import {ICosmicSignatureGame} from "../../src/ICosmicSignatureGame.sol";
import {MockCst, MockGame} from "./Mocks.sol";

/// @notice Shared fixture for all GestureSeriesMarket test suites: mocks, the
/// singleton series market, funded actors, and round/lifecycle helpers.
abstract contract SeriesTestBase is Test {
    uint16 internal constant TIER_LOW = 100; // 1%
    uint16 internal constant TIER_MID = 200; // 2%
    uint16 internal constant TIER_HIGH = 500; // 5%

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

        market = new GestureSeriesMarket(ICosmicSignatureGame(address(game)), _defaultTiers());

        address[5] memory actors = [lpAda, lpBen, alice, bob, carol];
        for (uint256 i = 0; i < actors.length; i++) {
            cst.mint(actors[i], 10_000_000e18);
            vm.prank(actors[i]);
            cst.approve(address(market), type(uint256).max);
        }
    }

    function _defaultTiers() internal pure returns (uint16[] memory tiers) {
        tiers = new uint16[](3);
        tiers[0] = TIER_LOW;
        tiers[1] = TIER_MID;
        tiers[2] = TIER_HIGH;
    }

    /// @dev Opens the (ROUND, tier) pool with `liq` CST at 50/50 odds via lpAda.
    function _seedPool(uint16 tier, uint256 liq) internal returns (uint256 shares) {
        vm.prank(lpAda);
        shares = market.addLiquidity(ROUND, tier, liq, 5_000, 0, NO_DEADLINE);
    }

    /// @dev Opens all three tiers of ROUND with `liq` each at 50/50 odds.
    function _seedAllPools(uint256 liq) internal {
        _seedPool(TIER_LOW, liq);
        _seedPool(TIER_MID, liq);
        _seedPool(TIER_HIGH, liq);
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

    function _reserves(uint256 roundId, uint16 tier) internal view returns (uint256 rY, uint256 rN) {
        (rY, rN,,,) = market.pool(roundId, tier);
    }

    function _totalShares(uint256 roundId, uint16 tier) internal view returns (uint256 shares) {
        (,, shares,,) = market.pool(roundId, tier);
    }

    function _feeReserve(uint256 roundId, uint16 tier) internal view returns (uint256 feeReserve) {
        (,,,, feeReserve) = market.pool(roundId, tier);
    }

    function _yesBal(address who) internal view returns (uint256 yes) {
        (yes,) = market.balancesOf(ROUND, who);
    }

    function _noBal(address who) internal view returns (uint256 no) {
        (, no) = market.balancesOf(ROUND, who);
    }

    /// @dev A pool's implied YES probability in bps: reserveNo / (rY + rN).
    function _probBps(uint256 roundId, uint16 tier) internal view returns (uint256) {
        (uint256 rY, uint256 rN) = _reserves(roundId, tier);
        if (rY + rN == 0) return 0;
        return rN * BPS / (rY + rN);
    }
}

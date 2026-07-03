// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GestureMarket} from "../../src/GestureMarket.sol";
import {ICosmicSignatureGame} from "../../src/ICosmicSignatureGame.sol";
import {MockCst, MockGame} from "./Mocks.sol";

/// @notice Shared fixture for all GestureMarket test suites: mocks, a default
/// market, funded actors, and deployment/round helpers.
abstract contract MarketTestBase is Test {
    uint256 internal constant MIN = 200;
    uint256 internal constant MAX = 1200;
    uint256 internal constant FEE_BPS = 100; // 1%
    uint256 internal constant LIQ = 10_000e18;
    uint256 internal constant ROUND = 5;
    uint256 internal constant ONE = 1e18;

    MockCst internal cst;
    MockGame internal game;
    GestureMarket internal market;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        cst = new MockCst();
        game = new MockGame(address(cst));
        game.setRoundNum(ROUND);

        market = _deployMarket(MIN, MAX, FEE_BPS, LIQ);

        address[3] memory actors = [alice, bob, carol];
        for (uint256 i = 0; i < actors.length; i++) {
            cst.mint(actors[i], 1_000_000e18);
            vm.prank(actors[i]);
            cst.approve(address(market), type(uint256).max);
        }
    }

    /// @dev The constructor pulls CST, so the creator approves the market's
    /// predicted address before deploying — same flow as the deploy script.
    function _deployMarket(uint256 min, uint256 max, uint256 feeBps, uint256 liq) internal returns (GestureMarket m) {
        cst.mint(creator, liq);
        address predicted = vm.computeCreateAddress(creator, vm.getNonce(creator));
        vm.prank(creator);
        cst.approve(predicted, type(uint256).max);
        vm.prank(creator);
        m = new GestureMarket(ICosmicSignatureGame(address(game)), min, max, feeBps, liq);
        assertEq(address(m), predicted, "address prediction");
    }

    function _endRoundWith(uint256 finalCount) internal {
        game.setNumBids(ROUND, finalCount);
        game.setRoundNum(ROUND + 1);
    }

    /// @dev Expected payout fraction for a final count, mirroring the contract's math.
    function _expectedPayoutPerHigher(uint256 finalCount, uint256 min, uint256 max) internal pure returns (uint256) {
        uint256 clamped = finalCount < min ? min : (finalCount > max ? max : finalCount);
        return (clamped - min) * ONE / (max - min);
    }
}

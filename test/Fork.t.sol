// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GestureSeriesMarket, IERC20} from "../src/GestureSeriesMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";

/// @notice Validates our minimal interface against the live Cosmic Signature
/// proxy on Arbitrum One and runs a full LP + bet flow against the series
/// market deployed on a fork. Skipped unless ARBITRUM_RPC_URL is set:
///
///   ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc forge test --match-contract ForkTest -vv
contract ForkTest is Test {
    address constant GAME = 0x6a714Ae7B5b6eA520F6BCA23d2E609C4Fd5863F2;
    address constant CST = 0xAD91843e6A58Ba560F577E676986AFb1dba6FBA0;

    function test_fork_liveGameInterfaceAndMarketFlow() external {
        string memory rpcUrl = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            emit log("Skipping fork test: ARBITRUM_RPC_URL not set");
            return;
        }
        vm.createSelectFork(rpcUrl);

        ICosmicSignatureGame game = ICosmicSignatureGame(GAME);
        assertEq(game.token(), CST, "token() getter");
        uint256 round = game.roundNum();
        emit log_named_uint("live roundNum", round);
        emit log_named_uint("threshold (previous round's count)", round > 0 ? game.bidderAddresses(round - 1) : 0);
        emit log_named_uint("gestures so far this round", game.bidderAddresses(round));
        if (round == 0) {
            emit log("Game still in round 0: series markets start at round 1; skipping flow");
            return;
        }

        uint16[] memory tiers = new uint16[](3);
        tiers[0] = 100;
        tiers[1] = 200;
        tiers[2] = 500;
        GestureSeriesMarket market = new GestureSeriesMarket(game, tiers);

        deal(CST, address(this), 10_000e18);
        IERC20(CST).approve(address(market), type(uint256).max);

        // The live count may already exceed the previous round's; then the
        // outcome is decided and the market correctly refuses to open.
        uint256 threshold = game.bidderAddresses(round - 1);
        uint256 current = game.bidderAddresses(round);
        if (current > threshold) {
            vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
            market.addLiquidity(round, 100, 1_000e18, 5_000, 0, type(uint256).max);
            emit log("Outcome already decided this round: init correctly refused");
            return;
        }

        market.addLiquidity(round, 100, 1_000e18, 5_000, 0, type(uint256).max);
        (bool initialized,,, uint256 storedThreshold,,,) = market.roundState(round);
        assertTrue(initialized);
        assertEq(storedThreshold, threshold, "threshold read from the live game");

        (uint16 bestTier, uint256 quoted) = market.quoteBetYesBest(round, 100e18);
        assertEq(bestTier, 100, "only funded tier must win routing");
        uint256 out = market.betYes(round, 100, 100e18, quoted, type(uint256).max);
        assertEq(out, quoted, "fork bet must match its quote");
        assertGt(out, 0);
    }
}

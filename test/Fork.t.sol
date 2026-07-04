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

        GestureSeriesMarket market = new GestureSeriesMarket(game);

        deal(CST, address(this), 10_000e18);
        IERC20(CST).approve(address(market), type(uint256).max);

        // The live count may already exceed the previous round's; then the
        // outcome is decided and the market correctly refuses to open.
        uint256 threshold = game.bidderAddresses(round - 1);
        uint256 current = game.bidderAddresses(round);
        if (current > threshold) {
            vm.expectRevert(GestureSeriesMarket.OutcomeDecided.selector);
            market.addLiquidity(round, 1_000e18, 200, 5_000, 0, type(uint256).max);
            emit log("Outcome already decided this round: init correctly refused");
            return;
        }

        market.addLiquidity(round, 1_000e18, 200, 5_000, 0, type(uint256).max);
        (bool initialized, bool thresholdKnown,,, uint256 storedThreshold,,,) = market.roundState(round);
        assertTrue(initialized);
        assertTrue(thresholdKnown, "current-round threshold locks at init");
        assertEq(storedThreshold, threshold, "threshold read from the live game");
        assertEq(market.currentFeeBps(round), 200, "sole LP's declaration is the fee");

        uint256 quoted = market.quoteBetYes(round, 100e18);
        uint256 out = market.betYes(round, 100e18, quoted, type(uint256).max);
        assertEq(out, quoted, "fork bet must match its quote");
        assertGt(out, 0);

        // Future rounds are open for business against the LIVE game too.
        uint256 future = round + 1;
        market.addLiquidity(future, 500e18, 200, 5_000, 0, type(uint256).max);
        (, bool futureKnown,,,,,,) = market.roundState(future);
        assertFalse(futureKnown, "a future round has no threshold yet");
        uint256 futureOut = market.betYes(future, 50e18, 0, type(uint256).max);
        assertGt(futureOut, 0, "future-round bet fills");
        vm.expectRevert(GestureSeriesMarket.NotResolvable.selector);
        market.resolve(future);
    }
}

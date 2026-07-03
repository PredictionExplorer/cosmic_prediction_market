// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GestureMarket, IERC20} from "../src/GestureMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";

/// @notice Validates our minimal interface against the live Cosmic Signature
/// proxy on Arbitrum One and runs a full bet against a market deployed on a fork.
/// Skipped unless ARBITRUM_RPC_URL is set:
///
///   ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc forge test --match-contract ForkTest -vv
contract ForkTest is Test {
    address constant GAME = 0x6a714Ae7B5b6eA520F6BCA23d2E609C4Fd5863F2;
    address constant CST = 0xAD91843e6A58Ba560F577E676986AFb1dba6FBA0;

    function test_fork_liveGameInterfaceAndBetFlow() external {
        string memory rpcUrl = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            emit log("Skipping fork test: ARBITRUM_RPC_URL not set");
            return;
        }
        vm.createSelectFork(rpcUrl);

        ICosmicSignatureGame game = ICosmicSignatureGame(GAME);
        assertEq(game.token(), CST, "token() getter");
        uint256 currentRound = game.roundNum();
        emit log_named_uint("live roundNum", currentRound);
        emit log_named_uint("gestures so far this round", game.bidderAddresses(currentRound));

        // Deploy a market for the live current round and place a real bet with dealt CST.
        deal(CST, address(this), 2_000e18);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        IERC20(CST).approve(predicted, type(uint256).max);
        GestureMarket market = new GestureMarket(game, 0, 2_000, 100, 1_000e18);
        assertEq(address(market), predicted);
        assertEq(market.round(), currentRound);
        assertEq(market.predictedCount(), 1_000, "opens at midpoint");

        IERC20(CST).approve(address(market), type(uint256).max);
        uint256 tokensOut = market.betHigher(500e18, 0);
        assertGt(tokensOut, 0);
        assertGt(market.predictedCount(), 1_000, "bet moved the prediction up");
    }
}

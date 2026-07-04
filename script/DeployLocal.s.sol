// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GestureSeriesMarket} from "../src/GestureSeriesMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";
import {MockCst, MockGame} from "../test/utils/Mocks.sol";

/// @notice Local sandbox for frontend development: deploys a mock CST token, a
/// mock game and the series market on anvil, seeds liquidity in all three fee
/// tiers for the current round, and funds the default anvil accounts.
///
///   anvil
///   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
///     --broadcast
contract DeployLocal is Script {
    uint256 constant ROUND = 3;
    uint256 constant PREV_ROUND_COUNT = 800; // the threshold to beat
    uint256 constant GESTURES_SO_FAR = 640;
    uint256 constant LIQ_PER_TIER = 5_000e18;
    uint256 constant INITIAL_YES_PROB_BPS = 4_500; // seed slightly below 50%

    function run() external {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        MockCst cst = new MockCst();
        MockGame game = new MockGame(address(cst));
        game.setRoundNum(ROUND);
        game.setNumBids(ROUND - 1, PREV_ROUND_COUNT);
        game.setNumBids(ROUND, GESTURES_SO_FAR);

        cst.mint(deployer, 1_000_000e18);
        // Default anvil accounts 1-3, for multi-wallet testing.
        cst.mint(0x70997970C51812dc3A010C7d01b50e0d17dc79C8, 100_000e18);
        cst.mint(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC, 100_000e18);
        cst.mint(0x90F79bf6EB2c4f870365E785982E1f101E93b906, 100_000e18);

        uint16[] memory tiers = new uint16[](3);
        tiers[0] = 100;
        tiers[1] = 200;
        tiers[2] = 500;
        GestureSeriesMarket market = new GestureSeriesMarket(ICosmicSignatureGame(address(game)), tiers);

        cst.approve(address(market), type(uint256).max);
        for (uint256 i = 0; i < tiers.length; i++) {
            market.addLiquidity(ROUND, tiers[i], LIQ_PER_TIER, INITIAL_YES_PROB_BPS, 0, type(uint256).max);
        }

        vm.stopBroadcast();

        console.log("MockCst:            ", address(cst));
        console.log("MockGame:           ", address(game));
        console.log("GestureSeriesMarket:", address(market));
        console.log("Round:", ROUND);
        console.log("Threshold (prev count):", PREV_ROUND_COUNT);
        console.log("Gestures so far:", GESTURES_SO_FAR);
    }
}

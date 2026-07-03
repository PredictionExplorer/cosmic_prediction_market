// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GestureMarket} from "../src/GestureMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";
import {MockCst, MockGame} from "../test/utils/Mocks.sol";

/// @notice Local sandbox for frontend development: deploys a mock CST token, a
/// mock game and a live GestureMarket on anvil, mints CST to the default anvil
/// accounts and seeds the game with some gestures.
///
///   anvil
///   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
///     --broadcast
contract DeployLocal is Script {
    uint256 constant MIN_COUNT = 200;
    uint256 constant MAX_COUNT = 1_200;
    uint256 constant FEE_BPS = 100;
    uint256 constant INITIAL_LIQUIDITY = 10_000e18;
    uint256 constant ROUND = 3;
    uint256 constant GESTURES_SO_FAR = 640;

    function run() external {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        MockCst cst = new MockCst();
        MockGame game = new MockGame(address(cst));
        game.setRoundNum(ROUND);
        game.setNumBids(ROUND, GESTURES_SO_FAR);

        cst.mint(deployer, 1_000_000e18);
        // Default anvil accounts 1-3, for multi-wallet testing.
        cst.mint(0x70997970C51812dc3A010C7d01b50e0d17dc79C8, 100_000e18);
        cst.mint(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC, 100_000e18);
        cst.mint(0x90F79bf6EB2c4f870365E785982E1f101E93b906, 100_000e18);

        address predictedMarket = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        cst.approve(predictedMarket, INITIAL_LIQUIDITY);
        GestureMarket market =
            new GestureMarket(ICosmicSignatureGame(address(game)), MIN_COUNT, MAX_COUNT, FEE_BPS, INITIAL_LIQUIDITY);

        vm.stopBroadcast();

        require(address(market) == predictedMarket, "address prediction mismatch");
        console.log("MockCst:      ", address(cst));
        console.log("MockGame:     ", address(game));
        console.log("GestureMarket:", address(market));
        console.log("Round:", market.round());
        console.log("Prediction:", market.predictedCount());
    }
}

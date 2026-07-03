// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GestureMarket, IERC20} from "../src/GestureMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";

/// @notice Deploys a GestureMarket for the CURRENT Cosmic Signature round on
/// Arbitrum One. The deployer wallet must hold at least INITIAL_LIQUIDITY CST.
///
/// Usage (env vars are optional, defaults shown):
///
///   MIN_COUNT=0 MAX_COUNT=2000 FEE_BPS=100 INITIAL_LIQUIDITY=1000000000000000000000 \
///   forge script script/Deploy.s.sol \
///     --rpc-url $ARBITRUM_RPC_URL --private-key $PRIVATE_KEY --broadcast
contract Deploy is Script {
    address constant GAME = 0x6a714Ae7B5b6eA520F6BCA23d2E609C4Fd5863F2;

    function run() external {
        uint256 minCount = vm.envOr("MIN_COUNT", uint256(0));
        uint256 maxCount = vm.envOr("MAX_COUNT", uint256(2_000));
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(100));
        uint256 initialLiquidity = vm.envOr("INITIAL_LIQUIDITY", uint256(1_000e18));

        ICosmicSignatureGame game = ICosmicSignatureGame(GAME);
        IERC20 cstToken = IERC20(game.token());

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        // The constructor pulls CST via transferFrom, so approve the market's
        // to-be address: the approve tx consumes the current nonce, the market
        // deploys at the next one.
        address predictedMarket = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        cstToken.approve(predictedMarket, initialLiquidity);
        GestureMarket market = new GestureMarket(game, minCount, maxCount, feeBps, initialLiquidity);

        vm.stopBroadcast();

        require(address(market) == predictedMarket, "address prediction mismatch");
        console.log("GestureMarket deployed at:", address(market));
        console.log("For round:", market.round());
        console.log("Range:", minCount, "-", maxCount);
        console.log("Opening prediction:", market.predictedCount());
    }
}

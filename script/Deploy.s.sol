// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Script, console} from "forge-std/Script.sol";
import {GestureSeriesMarket} from "../src/GestureSeriesMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";

/// @notice Deploys the GestureSeriesMarket singleton on Arbitrum One. Deploy
/// ONCE — every future Cosmic Signature round launches its own market lazily,
/// the first time someone adds liquidity for it. No per-round deployments, no
/// pre-funding, no configuration, no admin keys. The trading fee is a
/// liquidity-weighted vote by the LPs themselves.
///
///   cast wallet import pm-deployer --interactive   # one-time keystore setup
///   forge script script/Deploy.s.sol \
///     --rpc-url $ARBITRUM_RPC_URL --account pm-deployer --broadcast --verify
contract Deploy is Script {
    address constant GAME = 0x6a714Ae7B5b6eA520F6BCA23d2E609C4Fd5863F2;

    function run() external {
        vm.startBroadcast();
        GestureSeriesMarket market = new GestureSeriesMarket(ICosmicSignatureGame(GAME));
        vm.stopBroadcast();

        console.log("GestureSeriesMarket deployed at:", address(market));
        console.log("Current game round:", ICosmicSignatureGame(GAME).roundNum());
    }
}

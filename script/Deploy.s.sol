// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GestureSeriesMarket} from "../src/GestureSeriesMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";

/// @notice Deploys the GestureSeriesMarket singleton on Arbitrum One. Deploy
/// ONCE — every future Cosmic Signature round launches its own market lazily,
/// the first time someone adds liquidity for it. No per-round deployments, no
/// pre-funding, no admin keys.
///
/// Usage (FEE_TIERS is optional, defaults shown):
///
///   FEE_TIERS=100,200,500 \
///   forge script script/Deploy.s.sol \
///     --rpc-url $ARBITRUM_RPC_URL --private-key $PRIVATE_KEY --broadcast
contract Deploy is Script {
    address constant GAME = 0x6a714Ae7B5b6eA520F6BCA23d2E609C4Fd5863F2;

    function run() external {
        uint256[] memory rawTiers = vm.envOr("FEE_TIERS", ",", _defaultTiers());
        uint16[] memory tiers = new uint16[](rawTiers.length);
        for (uint256 i = 0; i < rawTiers.length; i++) {
            require(rawTiers[i] <= type(uint16).max, "tier overflow");
            tiers[i] = uint16(rawTiers[i]);
        }

        vm.startBroadcast();
        GestureSeriesMarket market = new GestureSeriesMarket(ICosmicSignatureGame(GAME), tiers);
        vm.stopBroadcast();

        console.log("GestureSeriesMarket deployed at:", address(market));
        console.log("Current game round:", ICosmicSignatureGame(GAME).roundNum());
        for (uint256 i = 0; i < tiers.length; i++) {
            console.log("Fee tier (bps):", tiers[i]);
        }
    }

    function _defaultTiers() internal pure returns (uint256[] memory tiers) {
        tiers = new uint256[](3);
        tiers[0] = 100;
        tiers[1] = 200;
        tiers[2] = 500;
    }
}

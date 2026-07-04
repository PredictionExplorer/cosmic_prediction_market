// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {GestureSeriesMarket} from "../src/GestureSeriesMarket.sol";
import {ICosmicSignatureGame} from "../src/ICosmicSignatureGame.sol";
import {MockCst, MockGame} from "../test/utils/Mocks.sol";

/// @notice Generates differential test vectors for the frontend: every number
/// is produced by executing the REAL contract, so the TypeScript math mirror
/// in `frontend/src/lib/math.ts` can be asserted bit-for-bit against Solidity.
/// The output is deterministic; CI regenerates it and fails on any drift.
///
///   forge script script/GenerateVectors.s.sol
///
/// writes frontend/src/test/fixtures/contract-vectors.json
contract GenerateVectors is Script {
    uint256 constant ROUND = 7;
    uint256 constant THRESHOLD = 800;
    uint16[3] TIERS = [uint16(100), 200, 500];

    MockCst cst;
    MockGame game;

    string out = "[";
    bool first = true;

    function run() external {
        // Pure swap-math vectors over a wide magnitude sweep.
        string memory buyAmountJson = _buyAmountVectors();
        // Full-flow vectors: open -> bet -> join -> bet -> remove, executed live.
        string memory flowsJson = _flowVectors();

        string memory json = string.concat("{\n\"buyAmount\": ", buyAmountJson, ",\n\"flows\": ", flowsJson, "\n}\n");
        vm.writeFile("frontend/src/test/fixtures/contract-vectors.json", json);
    }

    // ------------------------------------------------------------------
    // Pure _buyAmount sweep
    // ------------------------------------------------------------------

    function _buyAmountVectors() internal returns (string memory json) {
        _freshWorld();
        VectorHarness harness = new VectorHarness(ICosmicSignatureGame(address(game)), _tiers());

        json = "[";
        bool firstLocal = true;
        for (uint256 i = 0; i < 128; i++) {
            uint256 seed = uint256(keccak256(abi.encode("buyAmount", i)));
            // Magnitudes from wei-dust to 1e27, deliberately lopsided.
            uint256 reserveOut = _pick(seed, 0);
            uint256 reserveIn = _pick(seed, 1);
            uint256 net = _pick(seed, 2) % (1e27 + 1);
            uint256 tokensOut = harness.exposedBuyAmount(reserveOut, reserveIn, net);

            string memory entry = string.concat(
                '{"reserveOut":"',
                vm.toString(reserveOut),
                '","reserveIn":"',
                vm.toString(reserveIn),
                '","net":"',
                vm.toString(net),
                '","tokensOut":"',
                vm.toString(tokensOut),
                '"}'
            );
            json = string.concat(json, firstLocal ? "" : ",\n", entry);
            firstLocal = false;
        }
        json = string.concat(json, "]");
    }

    function _pick(uint256 seed, uint256 lane) internal pure returns (uint256) {
        uint256 r = uint256(keccak256(abi.encode(seed, lane)));
        uint256 magnitude = 1 + (r % 27); // 1e1 .. 1e27
        return 1 + (r >> 128) % (10 ** magnitude);
    }

    // ------------------------------------------------------------------
    // Executed lifecycle flows
    // ------------------------------------------------------------------

    function _flowVectors() internal returns (string memory) {
        for (uint256 i = 0; i < 48; i++) {
            _oneFlow(i);
        }
        return string.concat(out, "]");
    }

    GestureSeriesMarket market;
    uint16 tier;
    string obj;

    address constant ACTOR = address(0xA11CE);

    function _oneFlow(uint256 i) internal {
        uint256 seed = uint256(keccak256(abi.encode("flow", i)));
        _freshWorld();
        market = new GestureSeriesMarket(ICosmicSignatureGame(address(game)), _tiers());
        cst.mint(ACTOR, type(uint128).max);
        vm.prank(ACTOR);
        cst.approve(address(market), type(uint256).max);
        tier = TIERS[seed % 3];

        _stepOpen(1e15 + (seed >> 16) % 1e24, 100 + (seed >> 64) % 9_801);
        _stepBet(1 + (seed >> 96) % 1e23, (seed >> 128) % 2 == 0);
        _stepJoin(1e6 + (seed >> 160) % 1e23);
        _stepRemove();

        out = string.concat(out, first ? "" : ",\n", obj, "}");
        first = false;
    }

    function _stepOpen(uint256 liq, uint256 prob) internal {
        obj = string.concat(
            '{"tier":', vm.toString(tier), ',"liq":"', vm.toString(liq), '","probBps":', vm.toString(prob)
        );
        vm.prank(ACTOR);
        uint256 shares = market.addLiquidity(ROUND, tier, liq, prob, 0, type(uint256).max);
        obj = string.concat(obj, _poolJson("open"), ',"openShares":"', vm.toString(shares), '"');
    }

    function _stepBet(uint256 betAmount, bool betIsYes) internal {
        vm.prank(ACTOR);
        uint256 betOut = betIsYes
            ? market.betYes(ROUND, tier, betAmount, 0, type(uint256).max)
            : market.betNo(ROUND, tier, betAmount, 0, type(uint256).max);
        obj = string.concat(
            obj,
            ',"betYes":',
            betIsYes ? "true" : "false",
            ',"betAmount":"',
            vm.toString(betAmount),
            '","betOut":"',
            vm.toString(betOut),
            '"',
            _poolJson("postBet")
        );
    }

    function _stepJoin(uint256 joinAmount) internal {
        vm.prank(ACTOR);
        uint256 joinShares = market.addLiquidity(ROUND, tier, joinAmount, 0, 0, type(uint256).max);
        (uint256 joinYes, uint256 joinNo) = market.balancesOf(ROUND, ACTOR);
        obj = string.concat(
            obj,
            ',"joinAmount":"',
            vm.toString(joinAmount),
            '","joinShares":"',
            vm.toString(joinShares),
            '","balanceYesAfterJoin":"',
            vm.toString(joinYes),
            '","balanceNoAfterJoin":"',
            vm.toString(joinNo),
            '"',
            _poolJson("postJoin")
        );
    }

    function _stepRemove() internal {
        (uint256 held,) = market.lpPositionOf(ROUND, tier, ACTOR);
        vm.prank(ACTOR);
        (uint256 yesOut, uint256 noOut, uint256 feesOut) =
            market.removeLiquidity(ROUND, tier, held / 2, 0, 0, type(uint256).max);
        obj = string.concat(
            obj,
            ',"removeShares":"',
            vm.toString(held / 2),
            '","removeYes":"',
            vm.toString(yesOut),
            '","removeNo":"',
            vm.toString(noOut),
            '","removeFees":"',
            vm.toString(feesOut),
            '"',
            _poolJson("postRemove")
        );
    }

    function _poolJson(string memory prefix) internal view returns (string memory) {
        (uint256 rY, uint256 rN, uint256 totalShares, uint256 acc, uint256 feeReserve) = market.pool(ROUND, tier);
        return string.concat(
            ',"',
            prefix,
            'ReserveYes":"',
            vm.toString(rY),
            '","',
            prefix,
            'ReserveNo":"',
            vm.toString(rN),
            '","',
            prefix,
            'TotalShares":"',
            vm.toString(totalShares),
            '","',
            prefix,
            'AccFeePerShare":"',
            vm.toString(acc),
            '","',
            prefix,
            'FeeReserve":"',
            vm.toString(feeReserve),
            '"'
        );
    }

    function _freshWorld() internal {
        cst = new MockCst();
        game = new MockGame(address(cst));
        game.setRoundNum(ROUND);
        game.setNumBids(ROUND - 1, THRESHOLD);
    }

    function _tiers() internal view returns (uint16[] memory tiers) {
        tiers = new uint16[](3);
        tiers[0] = TIERS[0];
        tiers[1] = TIERS[1];
        tiers[2] = TIERS[2];
    }
}

contract VectorHarness is GestureSeriesMarket {
    constructor(ICosmicSignatureGame game_, uint16[] memory tiers) GestureSeriesMarket(game_, tiers) {}

    function exposedBuyAmount(uint256 reserveOut, uint256 reserveIn, uint256 net) external pure returns (uint256) {
        return _buyAmount(reserveOut, reserveIn, net);
    }
}

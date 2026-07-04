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
///   forge script script/GenerateVectors.s.sol --tc GenerateVectors
///
/// writes frontend/src/test/fixtures/contract-vectors.json
contract GenerateVectors is Script {
    uint256 constant ROUND = 7;
    uint256 constant THRESHOLD = 800;
    address constant ACTOR = address(0xA11CE);
    address constant JOINER = address(0xB0B);

    MockCst cst;
    MockGame game;

    string out = "[";
    bool first = true;

    function run() external {
        // Pure swap-math vectors over a wide magnitude sweep.
        string memory buyAmountJson = _buyAmountVectors();
        // Full-flow vectors: open -> bet -> join -> re-vote -> bet -> remove,
        // executed live against the contract.
        string memory flowsJson = _flowVectors();

        string memory json = string.concat("{\n\"buyAmount\": ", buyAmountJson, ",\n\"flows\": ", flowsJson, "\n}\n");
        vm.writeFile("frontend/src/test/fixtures/contract-vectors.json", json);
    }

    // ------------------------------------------------------------------
    // Pure _buyAmount sweep
    // ------------------------------------------------------------------

    function _buyAmountVectors() internal returns (string memory json) {
        _freshWorld();
        VectorHarness harness = new VectorHarness(ICosmicSignatureGame(address(game)));

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

    GestureSeriesMarket market;
    string obj;

    function _flowVectors() internal returns (string memory) {
        for (uint256 i = 0; i < 48; i++) {
            _oneFlow(i);
        }
        return string.concat(out, "]");
    }

    function _oneFlow(uint256 i) internal {
        uint256 seed = uint256(keccak256(abi.encode("flow", i)));
        _freshWorld();
        market = new GestureSeriesMarket(ICosmicSignatureGame(address(game)));
        cst.mint(ACTOR, type(uint128).max);
        cst.mint(JOINER, type(uint128).max);
        vm.prank(ACTOR);
        cst.approve(address(market), type(uint256).max);
        vm.prank(JOINER);
        cst.approve(address(market), type(uint256).max);

        // Casting is safe: every operand is reduced mod 1001 (max declaration + 1).
        // forge-lint: disable-next-line(unsafe-typecast)
        _stepOpen(1e15 + (seed >> 16) % 1e24, uint16(seed % 1_001), 100 + (seed >> 64) % 9_801);
        _stepBet(1 + (seed >> 96) % 1e23, (seed >> 128) % 2 == 0);
        _stepJoin(1e6 + (seed >> 160) % 1e23, uint16((seed >> 200) % 1_001));
        _stepRevote(uint16((seed >> 216) % 1_001));
        _stepBet2(1 + (seed >> 224) % 1e22);
        _stepRemove();

        out = string.concat(out, first ? "" : ",\n", obj, "}");
        first = false;
    }

    function _stepOpen(uint256 liq, uint16 decl, uint256 prob) internal {
        obj = string.concat(
            '{"liq":"', vm.toString(liq), '","openFeeBps":', vm.toString(decl), ',"probBps":', vm.toString(prob)
        );
        vm.prank(ACTOR);
        uint256 shares = market.addLiquidity(ROUND, liq, decl, prob, 0, type(uint256).max);
        obj = string.concat(obj, _poolJson("open"), ',"openShares":"', vm.toString(shares), '"');
    }

    function _stepBet(uint256 betAmount, bool betIsYes) internal {
        vm.prank(ACTOR);
        uint256 betOut = betIsYes
            ? market.betYes(ROUND, betAmount, 0, type(uint256).max)
            : market.betNo(ROUND, betAmount, 0, type(uint256).max);
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

    function _stepJoin(uint256 joinAmount, uint16 joinDecl) internal {
        vm.prank(JOINER);
        uint256 joinShares = market.addLiquidity(ROUND, joinAmount, joinDecl, 0, 0, type(uint256).max);
        (uint256 joinYes, uint256 joinNo) = market.balancesOf(ROUND, JOINER);
        obj = string.concat(
            obj,
            ',"joinAmount":"',
            vm.toString(joinAmount),
            '","joinFeeBps":',
            vm.toString(joinDecl),
            ',"joinShares":"',
            vm.toString(joinShares),
            '","joinerYesAfterJoin":"',
            vm.toString(joinYes),
            '","joinerNoAfterJoin":"',
            vm.toString(joinNo),
            '"',
            _poolJson("postJoin")
        );
    }

    function _stepRevote(uint16 newDecl) internal {
        vm.prank(ACTOR);
        market.updateFeeDeclaration(ROUND, newDecl);
        obj = string.concat(obj, ',"revoteFeeBps":', vm.toString(newDecl), _poolJson("postRevote"));
    }

    function _stepBet2(uint256 betAmount) internal {
        vm.prank(ACTOR);
        uint256 betOut = market.betYes(ROUND, betAmount, 0, type(uint256).max);
        obj = string.concat(
            obj,
            ',"bet2Amount":"',
            vm.toString(betAmount),
            '","bet2Out":"',
            vm.toString(betOut),
            '"',
            _poolJson("postBet2")
        );
    }

    function _stepRemove() internal {
        (uint256 held,,) = market.lpPositionOf(ROUND, ACTOR);
        vm.prank(ACTOR);
        (uint256 yesOut, uint256 noOut, uint256 feesOut) =
            market.removeLiquidity(ROUND, held / 2, 0, 0, type(uint256).max);
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

    function _poolJson(string memory prefix) internal view returns (string memory json) {
        (
            uint256 rY,
            uint256 rN,
            uint256 totalShares,
            uint256 acc,
            uint256 feeReserve,
            uint256 feeWeight,
            uint256 feeBps
        ) = market.pool(ROUND);
        json = string.concat(
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
            '"'
        );
        json = string.concat(
            json,
            ',"',
            prefix,
            'AccFeePerShare":"',
            vm.toString(acc),
            '","',
            prefix,
            'FeeReserve":"',
            vm.toString(feeReserve),
            '","',
            prefix,
            'FeeWeight":"',
            vm.toString(feeWeight),
            '","',
            prefix,
            'PoolFeeBps":"',
            vm.toString(feeBps),
            '"'
        );
    }

    function _freshWorld() internal {
        cst = new MockCst();
        game = new MockGame(address(cst));
        game.setRoundNum(ROUND);
        game.setNumBids(ROUND - 1, THRESHOLD);
    }
}

contract VectorHarness is GestureSeriesMarket {
    constructor(ICosmicSignatureGame game_) GestureSeriesMarket(game_) {}

    function exposedBuyAmount(uint256 reserveOut, uint256 reserveIn, uint256 net) external pure returns (uint256) {
        return _buyAmount(reserveOut, reserveIn, net);
    }
}

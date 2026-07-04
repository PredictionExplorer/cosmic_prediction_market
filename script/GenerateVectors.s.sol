// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

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
        // Lifecycle vectors: every round phase, with the GROUND TRUTH of
        // which actions the contract actually accepts, probed live.
        string memory lifecycleJson = _lifecycleVectors();

        string memory json = string.concat(
            "{\n\"buyAmount\": ",
            buyAmountJson,
            ",\n\"flows\": ",
            flowsJson,
            ",\n\"lifecycle\": ",
            lifecycleJson,
            "\n}\n"
        );
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

    // ------------------------------------------------------------------
    // Lifecycle & gating vectors
    // ------------------------------------------------------------------

    address constant PROBER = address(0xCA11);
    bool private lcFirst = true;
    string private lcOut = "[";

    /// @dev One record per lifecycle scenario: the full `roundState` tuple,
    /// the pool, and the GROUND TRUTH of which actions the contract accepts
    /// right now (probed with real calls on a state snapshot). The frontend's
    /// phase/gating helpers are asserted against these bit for bit.
    function _lifecycleVectors() internal returns (string memory) {
        // Current round, nobody funded it yet.
        _freshMarketWorld();
        _record("currentUninitialized", ROUND);

        // Current round, uninitialized, count already past the bar: the
        // market can never be opened.
        _freshMarketWorld();
        game.setNumBids(ROUND, THRESHOLD + 1);
        _record("currentUninitializedDecided", ROUND);

        // Live: funded, counting below the threshold.
        _freshMarketWorld();
        _openDefault(ROUND);
        game.setNumBids(ROUND, 500);
        _record("currentLive", ROUND);

        // A tie at the threshold is still live (strictly greater required).
        _freshMarketWorld();
        _openDefault(ROUND);
        game.setNumBids(ROUND, THRESHOLD);
        _record("tieAtThresholdStillLive", ROUND);

        // Decided mid-round: YES certain, withdraw-only except mint/resolve.
        _freshMarketWorld();
        _openDefault(ROUND);
        game.setNumBids(ROUND, THRESHOLD + 1);
        _record("currentDecided", ROUND);

        // Ended, unresolved: frozen, resolvable.
        _freshMarketWorld();
        _openDefault(ROUND);
        game.setNumBids(ROUND, 750);
        game.setRoundNum(ROUND + 1);
        _record("endedUnresolved", ROUND);

        // Resolved YES and NO.
        _freshMarketWorld();
        _openDefault(ROUND);
        game.setNumBids(ROUND, 900);
        game.setRoundNum(ROUND + 1);
        market.resolve(ROUND);
        _record("resolvedYes", ROUND);

        _freshMarketWorld();
        _openDefault(ROUND);
        game.setNumBids(ROUND, 750);
        game.setRoundNum(ROUND + 1);
        market.resolve(ROUND);
        _record("resolvedNo", ROUND);

        // Early-resolved while the round still runs.
        _freshMarketWorld();
        _openDefault(ROUND);
        game.setNumBids(ROUND, THRESHOLD + 1);
        market.resolve(ROUND);
        _record("earlyResolvedYes", ROUND);

        // Future round, uninitialized: fundable, nothing else.
        _freshMarketWorld();
        _record("futureUninitialized", ROUND + 2);

        // Future round, funded and traded: threshold unknown, fully open.
        _freshMarketWorld();
        _openDefault(ROUND + 2);
        vm.prank(ACTOR);
        market.betYes(ROUND + 2, 100e18, 0, type(uint256).max);
        _record("futureFunded", ROUND + 2);

        // Far-future round: same rules, arbitrarily far ahead.
        _freshMarketWorld();
        _openDefault(ROUND + 1000);
        _record("farFutureFunded", ROUND + 1000);

        // Future pool rugged down to dead-share dust: still technically
        // tradable and joinable (the AMM never fully empties).
        _freshMarketWorld();
        _openDefault(ROUND + 2);
        vm.startPrank(ACTOR);
        (uint256 lpShares,,) = market.lpPositionOf(ROUND + 2, ACTOR);
        market.removeLiquidity(ROUND + 2, lpShares, 0, 0, type(uint256).max);
        vm.stopPrank();
        _record("futureDustAfterLpExit", ROUND + 2);

        // Funded as future, now current: threshold knowable (not yet stored).
        _freshMarketWorld();
        _openDefault(ROUND + 1);
        game.setNumBids(ROUND, 950);
        game.setRoundNum(ROUND + 1);
        _record("futureTurnedCurrent", ROUND + 1);

        // Funded as future, whole life passed untouched: withdraw-only,
        // lazily resolvable.
        _freshMarketWorld();
        _openDefault(ROUND + 1);
        game.setNumBids(ROUND, 950);
        game.setNumBids(ROUND + 1, 900);
        game.setRoundNum(ROUND + 3);
        _record("futureLifePassedUntouched", ROUND + 1);

        // Past round, never initialized: dead forever.
        _freshMarketWorld();
        _record("pastUninitialized", ROUND - 4);

        // Round 0 can never host a market; round 1 is fundable as a future
        // round while round 0 still runs.
        _freshMarketWorld();
        game.setRoundNum(0);
        game.setNumBids(0, 42);
        _record("roundZeroDuringZero", 0);
        _record("roundOneDuringZero", 1);

        // Degenerate reveal: previous round ended with ZERO gestures, and
        // the first gesture decides YES instantly.
        _freshMarketWorld();
        game.setNumBids(ROUND - 1, 0);
        _openDefault(ROUND);
        game.setNumBids(ROUND, 1);
        _record("thresholdZeroInstantDecision", ROUND);

        return string.concat(lcOut, "]");
    }

    function _freshMarketWorld() internal {
        _freshWorld();
        market = new GestureSeriesMarket(ICosmicSignatureGame(address(game)));
        cst.mint(ACTOR, type(uint128).max);
        cst.mint(PROBER, type(uint128).max);
        vm.prank(ACTOR);
        cst.approve(address(market), type(uint256).max);
        vm.prank(PROBER);
        cst.approve(address(market), type(uint256).max);
    }

    function _openDefault(uint256 roundId) internal {
        vm.prank(ACTOR);
        market.addLiquidity(roundId, 10_000e18, 200, 5_000, 0, type(uint256).max);
    }

    function _record(string memory name, uint256 roundId) internal {
        string memory rec = string.concat(
            '{"name":"',
            name,
            '"',
            _lcIdsJson(roundId),
            _lcStateJson(roundId),
            _lcPoolJson(roundId),
            _lcProbesJson(roundId),
            "}"
        );
        lcOut = string.concat(lcOut, lcFirst ? "" : ",\n", rec);
        lcFirst = false;
    }

    function _lcIdsJson(uint256 roundId) internal view returns (string memory) {
        return string.concat(
            ',"roundId":"',
            vm.toString(roundId),
            '","gameRoundNum":"',
            vm.toString(game.roundNum()),
            '","prevRoundCount":"',
            vm.toString(roundId == 0 ? 0 : game.bidderAddresses(roundId - 1)),
            '"'
        );
    }

    function _lcStateJson(uint256 roundId) internal view returns (string memory json) {
        (
            bool initialized,
            bool thresholdKnown,
            bool resolved,
            bool yesWon,
            uint256 threshold,
            uint256 currentCount,
            bool roundActive,
            bool outcomeDecided
        ) = market.roundState(roundId);
        json = string.concat(
            ',"initialized":',
            _bool(initialized),
            ',"thresholdKnown":',
            _bool(thresholdKnown),
            ',"resolved":',
            _bool(resolved),
            ',"yesWon":',
            _bool(yesWon),
            ',"roundActive":',
            _bool(roundActive),
            ',"outcomeDecided":',
            _bool(outcomeDecided)
        );
        json = string.concat(
            json, ',"threshold":"', vm.toString(threshold), '","currentCount":"', vm.toString(currentCount), '"'
        );
    }

    function _lcProbesJson(uint256 roundId) internal returns (string memory) {
        return string.concat(
            ',"canAddLiquidity":',
            _probe(abi.encodeCall(market.addLiquidity, (roundId, 10e18, 200, 5_000, 0, type(uint256).max))),
            ',"canBet":',
            _probe(abi.encodeCall(market.betYes, (roundId, 1e18, 0, type(uint256).max))),
            ',"canMintSets":',
            _probe(abi.encodeCall(market.mintSets, (roundId, 1e18))),
            ',"canResolve":',
            _probe(abi.encodeCall(market.resolve, (roundId))),
            ',"canClaim":',
            _probe(abi.encodeCall(market.claim, (roundId)))
        );
    }

    /// @dev Executes a real call as PROBER against a state snapshot, records
    /// success/revert, and rolls the state back — pure ground truth.
    function _probe(bytes memory callData) internal returns (string memory) {
        uint256 snap = vm.snapshotState();
        vm.prank(PROBER);
        (bool ok,) = address(market).call(callData);
        vm.revertToState(snap);
        return _bool(ok);
    }

    function _bool(bool v) internal pure returns (string memory) {
        return v ? "true" : "false";
    }

    function _lcPoolJson(uint256 roundId) internal view returns (string memory) {
        (uint256 rY, uint256 rN, uint256 totalShares, uint256 acc, uint256 feeReserve, uint256 feeWeight,) =
            market.pool(roundId);
        return string.concat(
            ',"poolReserveYes":"',
            vm.toString(rY),
            '","poolReserveNo":"',
            vm.toString(rN),
            '","poolTotalShares":"',
            vm.toString(totalShares),
            '","poolAccFeePerShare":"',
            vm.toString(acc),
            '","poolFeeReserve":"',
            vm.toString(feeReserve),
            '","poolFeeWeight":"',
            vm.toString(feeWeight),
            '"'
        );
    }
}

contract VectorHarness is GestureSeriesMarket {
    constructor(ICosmicSignatureGame game_) GestureSeriesMarket(game_) {}

    function exposedBuyAmount(uint256 reserveOut, uint256 reserveIn, uint256 net) external pure returns (uint256) {
        return _buyAmount(reserveOut, reserveIn, net);
    }
}

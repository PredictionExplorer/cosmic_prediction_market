import { describe, expect, it } from "vitest";
import vectors from "@/test/fixtures/contract-vectors.json";
import type { PoolTuple, RoundPhase, RoundSnapshot, RoundStateTuple } from "./market";
import {
  canAddLiquidity,
  canClaim,
  canMintSets,
  displayedProbability,
  isResolvable,
  isTradable,
  roundPhase,
  toRoundSnapshot,
} from "./market";

const SERIES = "0x1111111111111111111111111111111111111111" as const;
const CST = "0x2222222222222222222222222222222222222222" as const;
const GAME = "0x3333333333333333333333333333333333333333" as const;

interface LifecycleVector {
  readonly name: string;
  readonly roundId: string;
  readonly gameRoundNum: string;
  readonly prevRoundCount: string;
  readonly initialized: boolean;
  readonly thresholdKnown: boolean;
  readonly resolved: boolean;
  readonly yesWon: boolean;
  readonly roundActive: boolean;
  readonly outcomeDecided: boolean;
  readonly threshold: string;
  readonly currentCount: string;
  readonly poolReserveYes: string;
  readonly poolReserveNo: string;
  readonly poolTotalShares: string;
  readonly poolAccFeePerShare: string;
  readonly poolFeeReserve: string;
  readonly poolFeeWeight: string;
  readonly canAddLiquidity: boolean;
  readonly canBet: boolean;
  readonly canMintSets: boolean;
  readonly canResolve: boolean;
  readonly canClaim: boolean;
}

const lifecycle = vectors.lifecycle as readonly LifecycleVector[];

/**
 * The phase the UI must derive for each scripted contract scenario. Every
 * vector name must appear here — a new scenario in the generator fails this
 * suite until it is classified.
 */
const EXPECTED_PHASE: Record<string, RoundPhase> = {
  currentUninitialized: "uninitialized",
  currentUninitializedDecided: "uninitialized",
  currentLive: "live",
  tieAtThresholdStillLive: "live",
  currentDecided: "decided",
  endedUnresolved: "ended",
  resolvedYes: "resolved",
  resolvedNo: "resolved",
  earlyResolvedYes: "resolved",
  futureUninitialized: "uninitialized",
  futureFunded: "future",
  farFutureFunded: "future",
  futureDustAfterLpExit: "future",
  futureTurnedCurrent: "live",
  futureLifePassedUntouched: "ended",
  pastUninitialized: "uninitialized",
  roundZeroDuringZero: "uninitialized",
  roundOneDuringZero: "uninitialized",
  thresholdZeroInstantDecision: "decided",
};

/** Rebuilds the snapshot exactly the way the app does: raw tuples in. */
function snapshotFrom(vec: LifecycleVector): RoundSnapshot {
  const state: RoundStateTuple = [
    vec.initialized,
    vec.thresholdKnown,
    vec.resolved,
    vec.yesWon,
    BigInt(vec.threshold),
    BigInt(vec.currentCount),
    vec.roundActive,
    vec.outcomeDecided,
  ];
  const pool: PoolTuple = [
    BigInt(vec.poolReserveYes),
    BigInt(vec.poolReserveNo),
    BigInt(vec.poolTotalShares),
    BigInt(vec.poolAccFeePerShare),
    BigInt(vec.poolFeeReserve),
    BigInt(vec.poolFeeWeight),
    0n, // feeBps: derived locally, ignored by the decoder
  ];
  return toRoundSnapshot({
    seriesAddress: SERIES,
    roundId: BigInt(vec.roundId),
    state,
    pool,
    gameRoundNum: BigInt(vec.gameRoundNum),
    prevRoundCount: BigInt(vec.prevRoundCount),
    cstAddress: CST,
    gameAddress: GAME,
  });
}

describe("lifecycle differential vectors from the contract", () => {
  it("covers every scenario in the phase table (and vice versa)", () => {
    const names = lifecycle.map((v) => v.name);
    expect(new Set(names).size).toBe(names.length);
    expect([...names].sort()).toEqual(Object.keys(EXPECTED_PHASE).sort());
  });

  it.each(lifecycle.map((vec) => [vec.name, vec] as const))(
    "%s: the UI's phase and gates match the contract's real behavior",
    (name, vec) => {
      const s = snapshotFrom(vec);

      expect(roundPhase(s)).toBe(EXPECTED_PHASE[name]);

      // The ground truth: each `can*` flag is whether the REAL call
      // succeeded on the real contract in this exact state.
      expect(canAddLiquidity(s), "canAddLiquidity").toBe(vec.canAddLiquidity);
      expect(isTradable(s), "isTradable vs betYes").toBe(vec.canBet);
      expect(canMintSets(s), "canMintSets").toBe(vec.canMintSets);
      expect(isResolvable(s), "isResolvable").toBe(vec.canResolve);
      expect(canClaim(s), "canClaim").toBe(vec.canClaim);
    },
  );

  it("agrees with the contract's own decided flag whenever the UI says decided", () => {
    for (const vec of lifecycle) {
      const s = snapshotFrom(vec);
      if (roundPhase(s) === "decided") {
        expect(vec.outcomeDecided).toBe(true);
      }
      // The contract's `outcomeDecided` covers uninitialized rounds too, so
      // the implication only runs one way.
    }
  });

  it("pins the displayed probability to the winner on resolved vectors", () => {
    for (const vec of lifecycle.filter((v) => v.resolved)) {
      const s = snapshotFrom(vec);
      expect(displayedProbability(s)).toBe(vec.yesWon ? 1 : 0);
    }
  });

  it("never shows a probability outside [0, 1]", () => {
    for (const vec of lifecycle) {
      const p = displayedProbability(snapshotFrom(vec));
      if (p !== null) {
        expect(p).toBeGreaterThanOrEqual(0);
        expect(p).toBeLessThanOrEqual(1);
      }
    }
  });
});

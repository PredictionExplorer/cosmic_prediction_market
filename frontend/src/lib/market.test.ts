import { describe, expect, it } from "vitest";
import type { RoundSnapshot } from "./market";
import {
  canAddLiquidity,
  displayedProbability,
  hasLpPosition,
  hasPosition,
  isResolvable,
  isTradable,
  positionValueFloat,
  poolForTier,
  roundPhase,
  thresholdProgress,
  totalFeeReserve,
  totalLiquidity,
} from "./market";
import { ONE } from "./math";

const SERIES = "0x1111111111111111111111111111111111111111" as const;
const CST = "0x2222222222222222222222222222222222222222" as const;
const GAME = "0x3333333333333333333333333333333333333333" as const;

function snapshot(overrides: Partial<RoundSnapshot> = {}): RoundSnapshot {
  return {
    seriesAddress: SERIES,
    roundId: 5n,
    initialized: true,
    resolved: false,
    yesWon: false,
    threshold: 800n,
    currentCount: 500n,
    gameRoundNum: 5n,
    pools: [
      {
        feeBps: 100,
        pool: {
          reserveYes: 1_000n * ONE,
          reserveNo: 1_000n * ONE,
          totalShares: 1_000n * ONE,
          accFeePerShare: 0n,
          feeReserve: 5n * ONE,
        },
      },
      {
        feeBps: 500,
        pool: {
          reserveYes: 300n * ONE,
          reserveNo: 100n * ONE,
          totalShares: 300n * ONE,
          accFeePerShare: 0n,
          feeReserve: 1n * ONE,
        },
      },
    ],
    cstAddress: CST,
    gameAddress: GAME,
    ...overrides,
  };
}

describe("roundPhase", () => {
  it("walks the full lifecycle", () => {
    expect(roundPhase(snapshot({ initialized: false }))).toBe("uninitialized");
    expect(roundPhase(snapshot())).toBe("live");
    expect(roundPhase(snapshot({ currentCount: 801n }))).toBe("decided");
    expect(roundPhase(snapshot({ gameRoundNum: 6n }))).toBe("ended");
    expect(roundPhase(snapshot({ resolved: true, yesWon: true }))).toBe("resolved");
  });

  it("a tie at the threshold is NOT decided (strictly greater required)", () => {
    expect(roundPhase(snapshot({ currentCount: 800n }))).toBe("live");
  });

  it("resolved wins over everything else", () => {
    expect(roundPhase(snapshot({ resolved: true, gameRoundNum: 9n, currentCount: 10_000n }))).toBe("resolved");
  });
});

describe("tradability and resolvability", () => {
  it("only live rounds are tradable", () => {
    expect(isTradable(snapshot())).toBe(true);
    expect(isTradable(snapshot({ currentCount: 801n }))).toBe(false);
    expect(isTradable(snapshot({ gameRoundNum: 6n }))).toBe(false);
    expect(isTradable(snapshot({ resolved: true }))).toBe(false);
  });

  it("decided and ended rounds are resolvable", () => {
    expect(isResolvable(snapshot())).toBe(false);
    expect(isResolvable(snapshot({ currentCount: 801n }))).toBe(true);
    expect(isResolvable(snapshot({ gameRoundNum: 6n }))).toBe(true);
    expect(isResolvable(snapshot({ resolved: true }))).toBe(false);
  });

  it("canAddLiquidity: live rounds, or open-able uninitialized current rounds", () => {
    expect(canAddLiquidity(snapshot())).toBe(true);
    expect(canAddLiquidity(snapshot({ initialized: false }))).toBe(true);
    // Uninitialized but the count already crossed: opening would revert.
    expect(canAddLiquidity(snapshot({ initialized: false, currentCount: 801n }))).toBe(false);
    // Uninitialized past/future rounds can't be opened.
    expect(canAddLiquidity(snapshot({ initialized: false, gameRoundNum: 6n }))).toBe(false);
    // Round 0 has no previous round.
    expect(canAddLiquidity(snapshot({ initialized: false, roundId: 0n, gameRoundNum: 0n }))).toBe(false);
    expect(canAddLiquidity(snapshot({ currentCount: 801n }))).toBe(false);
    expect(canAddLiquidity(snapshot({ resolved: true }))).toBe(false);
  });
});

describe("displayedProbability", () => {
  it("aggregates pools while live (liquidity-weighted)", () => {
    // reserveNo total = 1100, all reserves total = 2400.
    expect(displayedProbability(snapshot())).toBeCloseTo(1_100 / 2_400);
  });

  it("pins to 1 when decided and to the winner when resolved", () => {
    expect(displayedProbability(snapshot({ currentCount: 801n }))).toBe(1);
    expect(displayedProbability(snapshot({ resolved: true, yesWon: true }))).toBe(1);
    expect(displayedProbability(snapshot({ resolved: true, yesWon: false }))).toBe(0);
  });

  it("is null with no liquidity anywhere", () => {
    expect(displayedProbability(snapshot({ pools: [] }))).toBeNull();
  });
});

describe("positionValueFloat", () => {
  const user = { yesBalance: 10n * ONE, noBalance: 4n * ONE };

  it("resolved: exact claim value", () => {
    expect(positionValueFloat(snapshot({ resolved: true, yesWon: true }), user)).toBeCloseTo(10);
    expect(positionValueFloat(snapshot({ resolved: true, yesWon: false }), user)).toBeCloseTo(4);
  });

  it("decided: YES tokens at full value", () => {
    expect(positionValueFloat(snapshot({ currentCount: 801n }), user)).toBeCloseTo(10);
  });

  it("live: marked at the aggregate probability", () => {
    const p = 1_100 / 2_400;
    expect(positionValueFloat(snapshot(), user)).toBeCloseTo(10 * p + 4 * (1 - p));
  });
});

describe("aggregates and helpers", () => {
  it("totalLiquidity and totalFeeReserve sum across pools", () => {
    expect(totalLiquidity(snapshot().pools)).toBe(2_400n * ONE);
    expect(totalFeeReserve(snapshot().pools)).toBe(6n * ONE);
  });

  it("poolForTier finds exact tiers only", () => {
    expect(poolForTier(snapshot().pools, 100)?.reserveYes).toBe(1_000n * ONE);
    expect(poolForTier(snapshot().pools, 123)).toBeNull();
  });

  it("hasPosition / hasLpPosition", () => {
    expect(hasPosition({ yesBalance: 0n, noBalance: 0n })).toBe(false);
    expect(hasPosition({ yesBalance: 1n, noBalance: 0n })).toBe(true);
    expect(hasLpPosition({ lpPositions: [] })).toBe(false);
    expect(hasLpPosition({ lpPositions: [{ feeBps: 100, shares: 0n, pendingFees: 1n }] })).toBe(true);
  });

  it("thresholdProgress caps sensibly", () => {
    expect(thresholdProgress({ currentCount: 400n, threshold: 800n })).toBeCloseTo(0.5);
    expect(thresholdProgress({ currentCount: 900n, threshold: 800n })).toBeGreaterThan(1);
    expect(thresholdProgress({ currentCount: 5n, threshold: 0n })).toBe(1);
    expect(thresholdProgress({ currentCount: 0n, threshold: 0n })).toBe(0);
  });
});

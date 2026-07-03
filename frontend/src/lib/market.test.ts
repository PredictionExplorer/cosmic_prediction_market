import { describe, expect, it } from "vitest";
import type { MarketSnapshot, UserSnapshot } from "./market";
import { displayedPrediction, hasPosition, marketPhase, positionValue } from "./market";
import { ONE } from "./math";

const BASE: MarketSnapshot = {
  address: "0x1111111111111111111111111111111111111111",
  round: 5n,
  minCount: 200n,
  maxCount: 1_200n,
  feeBps: 100n,
  reserveHigher: 10_000n * ONE,
  reserveLower: 10_000n * ONE,
  resolved: false,
  finalGestureCount: 0n,
  payoutPerHigher: 0n,
  creator: "0x2222222222222222222222222222222222222222",
  cstAddress: "0x3333333333333333333333333333333333333333",
  gameAddress: "0x4444444444444444444444444444444444444444",
  feesAccrued: 0n,
  gameRoundNum: 5n,
  liveGestureCount: 640n,
};

const NO_POSITION: UserSnapshot = {
  address: "0x5555555555555555555555555555555555555555",
  higherBalance: 0n,
  lowerBalance: 0n,
  cstBalance: 100n * ONE,
  cstAllowance: 0n,
};

describe("marketPhase", () => {
  it("is live while the game is still on the market's round", () => {
    expect(marketPhase(BASE)).toBe("live");
  });

  it("is ended once the game's round counter advances", () => {
    expect(marketPhase({ ...BASE, gameRoundNum: 6n })).toBe("ended");
    expect(marketPhase({ ...BASE, gameRoundNum: 100n })).toBe("ended");
  });

  it("is resolved once resolve() ran, regardless of round counters", () => {
    expect(marketPhase({ ...BASE, resolved: true, gameRoundNum: 6n })).toBe("resolved");
  });
});

describe("displayedPrediction", () => {
  it("reads the pool while live", () => {
    expect(displayedPrediction(BASE)).toBeCloseTo(700, 6);
  });

  it("shows the clamped final count once resolved", () => {
    const resolved = { ...BASE, resolved: true, gameRoundNum: 6n, finalGestureCount: 950n, payoutPerHigher: (75n * ONE) / 100n };
    expect(displayedPrediction(resolved)).toBe(950);
    expect(displayedPrediction({ ...resolved, finalGestureCount: 5_000n })).toBe(1_200);
    expect(displayedPrediction({ ...resolved, finalGestureCount: 3n })).toBe(200);
  });
});

describe("positionValue", () => {
  it("is zero without tokens", () => {
    expect(positionValue(BASE, NO_POSITION)).toBe(0n);
  });

  it("uses the exact payout rate after resolution", () => {
    const market = { ...BASE, resolved: true, payoutPerHigher: (8n * ONE) / 10n };
    const user = { ...NO_POSITION, higherBalance: 100n * ONE, lowerBalance: 10n * ONE };
    // 100 * 0.8 + 10 * 0.2 = 82
    expect(positionValue(market, user)).toBe(82n * ONE);
  });

  it("marks to the live gesture count before resolution", () => {
    // live count 640 ⇒ f = (640-200)/1000 = 0.44
    const user = { ...NO_POSITION, higherBalance: 100n * ONE };
    expect(positionValue(BASE, user)).toBe(44n * ONE);
  });

  it("clamps live counts outside the range", () => {
    const user = { ...NO_POSITION, higherBalance: 100n * ONE };
    expect(positionValue({ ...BASE, liveGestureCount: 0n }, user)).toBe(0n);
    expect(positionValue({ ...BASE, liveGestureCount: 99_999n }, user)).toBe(100n * ONE);
  });
});

describe("hasPosition", () => {
  it("detects any nonzero balance", () => {
    expect(hasPosition(NO_POSITION)).toBe(false);
    expect(hasPosition({ ...NO_POSITION, higherBalance: 1n })).toBe(true);
    expect(hasPosition({ ...NO_POSITION, lowerBalance: 1n })).toBe(true);
  });
});

import fc from "fast-check";
import { describe, expect, it } from "vitest";
import type { BetEvent } from "./history";
import { replayHistory, sortEvents, unwindToOpeningPool } from "./history";
import { applyBet, ONE, type PoolState } from "./math";

const RANGE = { minCount: 200n, maxCount: 1_200n };
const LIQ = 10_000n * ONE;
const FEE = 100n;

function makeEvent(partial: Partial<BetEvent> & Pick<BetEvent, "side" | "cstIn">, i: number): BetEvent {
  return {
    blockNumber: partial.blockNumber ?? BigInt(100 + i),
    logIndex: partial.logIndex ?? i,
    transactionHash: partial.transactionHash ?? (`0x${i.toString(16).padStart(64, "0")}` as `0x${string}`),
    user: partial.user ?? "0x000000000000000000000000000000000000dEaD",
    side: partial.side,
    cstIn: partial.cstIn,
    tokensOut: partial.tokensOut ?? 0n,
    timestamp: partial.timestamp ?? null,
  };
}

describe("sortEvents", () => {
  it("orders by block number then log index", () => {
    const events = [
      { blockNumber: 5n, logIndex: 2 },
      { blockNumber: 3n, logIndex: 9 },
      { blockNumber: 5n, logIndex: 0 },
      { blockNumber: 1n, logIndex: 4 },
    ];
    const sorted = sortEvents(events);
    expect(sorted.map((e) => `${e.blockNumber}:${e.logIndex}`)).toEqual(["1:4", "3:9", "5:0", "5:2"]);
  });

  it("does not mutate the input", () => {
    const events = [
      { blockNumber: 5n, logIndex: 2 },
      { blockNumber: 1n, logIndex: 4 },
    ];
    sortEvents(events);
    expect(events[0].blockNumber).toBe(5n);
  });
});

describe("replayHistory", () => {
  it("starts at the opening midpoint with no events", () => {
    const { points, endPool } = replayHistory(RANGE, LIQ, FEE, []);
    expect(points).toHaveLength(1);
    expect(points[0].predicted).toBeCloseTo(700, 6);
    expect(endPool).toEqual({ reserveHigher: LIQ, reserveLower: LIQ });
  });

  it("replays a known sequence to the same end pool as direct application", () => {
    let pool: PoolState = { reserveHigher: LIQ, reserveLower: LIQ };
    const bets: Array<{ side: "higher" | "lower"; cstIn: bigint; tokensOut: bigint }> = [];
    for (const [side, cstIn] of [
      ["higher", 5_000n * ONE],
      ["lower", 2_000n * ONE],
      ["higher", 123n * ONE],
    ] as const) {
      const r = applyBet(side, pool, cstIn, FEE);
      bets.push({ side, cstIn, tokensOut: r.tokensOut });
      pool = r.pool;
    }
    const events = bets.map((b, i) => makeEvent(b, i));

    const { points, endPool } = replayHistory(RANGE, LIQ, FEE, events);
    expect(endPool).toEqual(pool);
    expect(points).toHaveLength(4);
    // First bet was HIGHER, so the prediction must have risen from the midpoint.
    expect(points[1].predicted).toBeGreaterThan(points[0].predicted);
    // Second bet was LOWER, prediction falls.
    expect(points[2].predicted).toBeLessThan(points[1].predicted);
  });

  it("property: replay end pool always matches sequential application, any event order given", () => {
    const arbBet = fc.record({
      side: fc.constantFrom("higher" as const, "lower" as const),
      cstIn: fc.bigInt({ min: ONE / 100n, max: 10n ** 23n }),
    });
    fc.assert(
      fc.property(fc.array(arbBet, { maxLength: 25 }), (bets) => {
        let pool: PoolState = { reserveHigher: LIQ, reserveLower: LIQ };
        const events: BetEvent[] = [];
        bets.forEach((b, i) => {
          const r = applyBet(b.side, pool, b.cstIn, FEE);
          events.push(makeEvent({ ...b, tokensOut: r.tokensOut }, i));
          pool = r.pool;
        });
        // Shuffle deterministically: replay must re-sort into chain order itself.
        const shuffled = [...events].reverse();
        const { points, endPool } = replayHistory(RANGE, LIQ, FEE, shuffled);
        expect(endPool).toEqual(pool);
        expect(points).toHaveLength(bets.length + 1);
        for (const p of points) {
          expect(p.predicted).toBeGreaterThanOrEqual(200);
          expect(p.predicted).toBeLessThanOrEqual(1_200);
        }
      }),
    );
  });
});

describe("unwindToOpeningPool", () => {
  it("property: unwinding recorded events recovers the opening pool exactly", () => {
    const arbBet = fc.record({
      side: fc.constantFrom("higher" as const, "lower" as const),
      cstIn: fc.bigInt({ min: ONE / 100n, max: 10n ** 23n }),
    });
    fc.assert(
      fc.property(fc.array(arbBet, { maxLength: 25 }), (bets) => {
        let pool: PoolState = { reserveHigher: LIQ, reserveLower: LIQ };
        const events: BetEvent[] = [];
        bets.forEach((b, i) => {
          const r = applyBet(b.side, pool, b.cstIn, FEE);
          events.push(makeEvent({ ...b, tokensOut: r.tokensOut }, i));
          pool = r.pool;
        });
        const recovered = unwindToOpeningPool(pool, FEE, events);
        expect(recovered).toEqual({ reserveHigher: LIQ, reserveLower: LIQ });
      }),
    );
  });
});

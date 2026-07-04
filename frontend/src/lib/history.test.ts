import fc from "fast-check";
import { describe, expect, it } from "vitest";
import type { BetEvent, LiquidityAddedEvent, LiquidityRemovedEvent, PoolEvent } from "./history";
import { applyPoolEvent, replayRound, sortEvents } from "./history";
import type { PoolState } from "./math";
import { applyBet, DEAD_SHARES, EMPTY_POOL, joinPool, ONE, openPool, removeLiquidity, takeFee } from "./math";

/**
 * Simulates a contract execution with the math lib while emitting the exact
 * events the contract would, then checks `replayRound` reconstructs the same
 * end state from the events alone. This is the roundtrip that guarantees the
 * chart is a faithful reconstruction of on-chain history.
 */

interface SimStep {
  readonly action: "open" | "join" | "removeHalf" | "betYes" | "betNo";
  readonly amount: bigint;
}

const TIER = 200;
const HEX = "0xabc" as `0x${string}`;
const USER = "0x1111111111111111111111111111111111111111" as `0x${string}`;

const arbStep: fc.Arbitrary<SimStep> = fc.record({
  action: fc.constantFrom("join", "removeHalf", "betYes", "betNo") as fc.Arbitrary<SimStep["action"]>,
  amount: fc.bigInt({ min: 10n ** 6n, max: 10n ** 23n }),
});

function simulate(
  openAmount: bigint,
  probBps: bigint,
  steps: readonly SimStep[],
  tier: number = TIER,
  startLogIndex = 0,
): {
  events: PoolEvent[];
  endPool: PoolState;
} {
  const events: PoolEvent[] = [];
  let logIndex = startLogIndex;
  let sharesHeld: bigint;
  const base = () => ({
    blockNumber: 1n,
    logIndex: logIndex++,
    transactionHash: HEX,
    timestamp: null,
    feeBps: tier,
  });

  const opened = openPool(openAmount, probBps);
  let pool = opened.pool;
  sharesHeld = opened.sharesOut;
  events.push({
    kind: "add",
    ...base(),
    provider: USER,
    cstIn: openAmount,
    sharesOut: opened.sharesOut,
    yesToPool: pool.reserveYes,
    noToPool: pool.reserveNo,
  } satisfies LiquidityAddedEvent);

  for (const step of steps) {
    if (step.action === "join") {
      const joined = joinPool(pool, step.amount);
      if (joined === null) continue;
      events.push({
        kind: "add",
        ...base(),
        provider: USER,
        cstIn: step.amount,
        sharesOut: joined.sharesOut,
        yesToPool: joined.depositYes,
        noToPool: joined.depositNo,
      } satisfies LiquidityAddedEvent);
      pool = joined.pool;
      sharesHeld += joined.sharesOut;
    } else if (step.action === "removeHalf") {
      const shares = sharesHeld / 2n;
      if (shares === 0n) continue;
      const removed = removeLiquidity(pool, shares);
      events.push({
        kind: "remove",
        ...base(),
        provider: USER,
        sharesIn: shares,
        yesOut: removed.yesOut,
        noOut: removed.noOut,
        feesOut: 0n,
      } satisfies LiquidityRemovedEvent);
      pool = removed.pool;
      sharesHeld -= shares;
    } else {
      const side = step.action === "betYes" ? "yes" : "no";
      const result = applyBet(side, pool, step.amount, BigInt(tier));
      const { net } = takeFee(step.amount, BigInt(tier));
      events.push({
        kind: "bet",
        ...base(),
        user: USER,
        side,
        cstIn: step.amount,
        netIn: net,
        tokensOut: result.tokensOut,
      } satisfies BetEvent);
      pool = result.pool;
    }
  }
  return { events, endPool: pool };
}

describe("applyPoolEvent", () => {
  it("adds dead shares exactly once, on the opening deposit", () => {
    const opened = openPool(10n ** 18n, 5_000n);
    const afterOpen = applyPoolEvent(EMPTY_POOL, {
      kind: "add",
      blockNumber: 1n,
      logIndex: 0,
      transactionHash: HEX,
      provider: USER,
      feeBps: TIER,
      cstIn: 10n ** 18n,
      sharesOut: opened.sharesOut,
      yesToPool: opened.pool.reserveYes,
      noToPool: opened.pool.reserveNo,
      timestamp: null,
    });
    expect(afterOpen.totalShares).toBe(opened.sharesOut + DEAD_SHARES);
    expect(afterOpen.totalShares).toBe(opened.pool.totalShares);
  });
});

describe("replayRound", () => {
  it("property: replaying emitted events reconstructs the exact end pool", () => {
    fc.assert(
      fc.property(
        fc.bigInt({ min: 10n ** 15n, max: 10n ** 23n }),
        fc.bigInt({ min: 100n, max: 9_900n }),
        fc.array(arbStep, { maxLength: 12 }),
        (openAmount, probBps, steps) => {
          const { events, endPool } = simulate(openAmount, probBps, steps);
          const replayed = replayRound(events);
          const tier = replayed.pools.find((p) => p.feeBps === TIER);
          expect(tier).toBeDefined();
          expect(tier!.pool.reserveYes).toBe(endPool.reserveYes);
          expect(tier!.pool.reserveNo).toBe(endPool.reserveNo);
          expect(tier!.pool.totalShares).toBe(endPool.totalShares);
          expect(tier!.pool.accFeePerShare).toBe(endPool.accFeePerShare);
          expect(tier!.pool.feeReserve).toBe(endPool.feeReserve);
        },
      ),
    );
  });

  it("property: every chart point is a probability in [0, 1]", () => {
    fc.assert(
      fc.property(
        fc.bigInt({ min: 10n ** 15n, max: 10n ** 23n }),
        fc.bigInt({ min: 100n, max: 9_900n }),
        fc.array(arbStep, { maxLength: 12 }),
        (openAmount, probBps, steps) => {
          const { events } = simulate(openAmount, probBps, steps);
          const { points } = replayRound(events);
          expect(points.length).toBeGreaterThan(0);
          for (const point of points) {
            expect(point.probability).toBeGreaterThanOrEqual(0);
            expect(point.probability).toBeLessThanOrEqual(1);
          }
        },
      ),
    );
  });

  it("the opening point sits at the first LP's chosen odds", () => {
    const { events } = simulate(1_000n * ONE, 3_000n, []);
    const { points } = replayRound(events);
    expect(points[0].probability).toBeCloseTo(0.3, 3);
  });

  it("handles multiple tiers independently", () => {
    const steps: SimStep[] = [
      { action: "betYes", amount: 100n * ONE },
      { action: "join", amount: 250n * ONE },
      { action: "betNo", amount: 40n * ONE },
    ];
    const a = simulate(1_000n * ONE, 4_000n, steps, TIER, 0);
    const b = simulate(2_000n * ONE, 7_000n, steps, 500, 100);
    const { pools } = replayRound([...a.events, ...b.events]);
    expect(pools.map((p) => p.feeBps)).toEqual([TIER, 500]);
    const tierA = pools.find((p) => p.feeBps === TIER)!.pool;
    const tierB = pools.find((p) => p.feeBps === 500)!.pool;
    expect(tierA).toEqual(a.endPool);
    expect(tierB).toEqual(b.endPool);
  });
});

describe("sortEvents", () => {
  it("orders by block then log index", () => {
    const mk = (blockNumber: bigint, logIndex: number) => ({ blockNumber, logIndex });
    const sorted = sortEvents([mk(2n, 0), mk(1n, 5), mk(1n, 2), mk(3n, 1)]);
    expect(sorted.map((e) => [e.blockNumber, e.logIndex])).toEqual([
      [1n, 2],
      [1n, 5],
      [2n, 0],
      [3n, 1],
    ]);
  });
});

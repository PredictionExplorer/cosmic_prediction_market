import fc from "fast-check";
import { describe, expect, it } from "vitest";
import { EMPTY_POOL, poolIsTradable } from "./math";
import type { PoolTuple, RoundSnapshot, RoundStateTuple } from "./market";
import {
  canAddLiquidity,
  canClaim,
  canMintSets,
  displayedProbability,
  isResolvable,
  isTradable,
  positionValueFloat,
  roundPhase,
  toRoundSnapshot,
} from "./market";

const SERIES = "0x1111111111111111111111111111111111111111" as const;
const CST = "0x2222222222222222222222222222222222222222" as const;
const GAME = "0x3333333333333333333333333333333333333333" as const;

// ---------------------------------------------------------------------
// Reachable round states
// ---------------------------------------------------------------------

/**
 * Generates only states the CONTRACT can actually reach:
 *  - round 0 can never be initialized;
 *  - `thresholdKnown` iff the round has a previous round and the game has
 *    reached it (the exact `roundState` formula; a storage lock implies the
 *    same because the game's round counter only grows);
 *  - a future round's own count is 0 (bids only happen in started rounds);
 *  - `resolved` requires a market and a resolvable condition (round over, or
 *    live count strictly above the threshold);
 *  - initialized rounds always have an opened pool (init happens via
 *    `addLiquidity`), at worst drained to dead-share dust; uninitialized
 *    rounds have an empty pool.
 */
const arbReachableSnapshot: fc.Arbitrary<RoundSnapshot> = fc
  .record({
    roundId: fc.bigInt({ min: 0n, max: 1_000n }),
    gameOffset: fc.bigInt({ min: -10n, max: 10n }),
    initializedSeed: fc.boolean(),
    resolvedSeed: fc.boolean(),
    yesWon: fc.boolean(),
    thresholdSeed: fc.bigInt({ min: 0n, max: 10n ** 9n }),
    countSeed: fc.bigInt({ min: 0n, max: 10n ** 9n }),
    prevCountSeed: fc.bigInt({ min: 0n, max: 10n ** 9n }),
    reserveYes: fc.bigInt({ min: 1n, max: 10n ** 27n }),
    reserveNo: fc.bigInt({ min: 1n, max: 10n ** 27n }),
    totalShares: fc.bigInt({ min: 1_000n, max: 10n ** 27n }),
    feeVoteBps: fc.bigInt({ min: 0n, max: 1_000n }),
    feeReserve: fc.bigInt({ min: 0n, max: 10n ** 24n }),
  })
  .map((r) => {
    const sum = r.roundId + r.gameOffset;
    const gameRoundNum = sum < 0n ? 0n : sum;
    const initialized = r.initializedSeed && r.roundId >= 1n;
    const thresholdKnown = r.roundId >= 1n && gameRoundNum >= r.roundId;
    const threshold = thresholdKnown ? r.thresholdSeed : 0n;
    const currentCount = r.roundId > gameRoundNum ? 0n : r.countSeed;
    const resolvable = gameRoundNum > r.roundId || (thresholdKnown && currentCount > threshold);
    const resolved = r.resolvedSeed && initialized && resolvable;
    const pool = initialized
      ? {
          reserveYes: r.reserveYes,
          reserveNo: r.reserveNo,
          totalShares: r.totalShares,
          accFeePerShare: 0n,
          feeReserve: r.feeReserve,
          feeWeight: r.totalShares * r.feeVoteBps,
        }
      : EMPTY_POOL;
    return {
      seriesAddress: SERIES,
      roundId: r.roundId,
      initialized,
      thresholdKnown,
      resolved,
      yesWon: resolved && r.yesWon,
      threshold,
      currentCount,
      gameRoundNum,
      prevRoundCount: thresholdKnown ? threshold : r.prevCountSeed,
      pool,
      cstAddress: CST,
      gameAddress: GAME,
    } satisfies RoundSnapshot;
  });

// ---------------------------------------------------------------------
// The contract's gating rules, written down independently as an oracle
// ---------------------------------------------------------------------

/** `addLiquidity` succeeds iff: not round 0, current-or-future, unresolved,
 * outcome not decided. (Mirrors the Solidity gates line by line.) */
function oracleCanAddLiquidity(s: RoundSnapshot): boolean {
  return (
    s.roundId >= 1n &&
    s.roundId >= s.gameRoundNum &&
    !s.resolved &&
    !(s.thresholdKnown && s.currentCount > s.threshold)
  );
}

/** Bets succeed iff: market exists, unresolved, current-or-future, outcome
 * not decided, and the pool can quote. */
function oracleIsTradable(s: RoundSnapshot): boolean {
  return (
    s.initialized &&
    !s.resolved &&
    s.roundId >= s.gameRoundNum &&
    !(s.thresholdKnown && s.currentCount > s.threshold) &&
    poolIsTradable(s.pool)
  );
}

/** `mintSets` succeeds iff: market exists, unresolved, current-or-future
 * (minting stays open on decided rounds — sets are value-neutral). */
function oracleCanMintSets(s: RoundSnapshot): boolean {
  return s.initialized && !s.resolved && s.roundId >= s.gameRoundNum;
}

/** `resolve` succeeds iff: market exists, unresolved, and the round is over
 * OR the live count already exceeds the (known) threshold. */
function oracleIsResolvable(s: RoundSnapshot): boolean {
  return (
    s.initialized &&
    !s.resolved &&
    (s.gameRoundNum > s.roundId || (s.thresholdKnown && s.currentCount > s.threshold))
  );
}

describe("roundPhase: fuzzed invariants over reachable states", () => {
  it("property: the phase partition matches the state flags exactly", () => {
    fc.assert(
      fc.property(arbReachableSnapshot, (s) => {
        const phase = roundPhase(s);
        switch (phase) {
          case "resolved":
            expect(s.resolved).toBe(true);
            break;
          case "uninitialized":
            expect(s.initialized).toBe(false);
            break;
          case "future":
            expect(s.initialized && !s.resolved && s.roundId > s.gameRoundNum).toBe(true);
            break;
          case "ended":
            expect(s.initialized && !s.resolved && s.gameRoundNum > s.roundId).toBe(true);
            break;
          case "decided":
            expect(s.roundId).toBe(s.gameRoundNum);
            expect(s.thresholdKnown && s.currentCount > s.threshold).toBe(true);
            break;
          case "live":
            expect(s.roundId).toBe(s.gameRoundNum);
            expect(s.currentCount <= s.threshold).toBe(true);
            break;
        }
      }),
    );
  });

  it("property: resolved dominates every other flag combination", () => {
    fc.assert(
      fc.property(arbReachableSnapshot, (s) => {
        if (s.resolved) expect(roundPhase(s)).toBe("resolved");
      }),
    );
  });

  it("property: a future round is never decided, resolvable, or claimable", () => {
    fc.assert(
      fc.property(arbReachableSnapshot, (s) => {
        fc.pre(s.roundId > s.gameRoundNum && !s.resolved);
        expect(roundPhase(s)).not.toBe("decided");
        expect(isResolvable(s)).toBe(false);
        expect(canClaim(s)).toBe(false);
      }),
    );
  });

  it("property: past unresolved rounds are frozen — nothing can enter", () => {
    fc.assert(
      fc.property(arbReachableSnapshot, (s) => {
        fc.pre(s.gameRoundNum > s.roundId && !s.resolved);
        expect(isTradable(s)).toBe(false);
        expect(canAddLiquidity(s)).toBe(false);
        expect(canMintSets(s)).toBe(false);
        expect(isResolvable(s)).toBe(s.initialized);
      }),
    );
  });

  it("property: claimable rounds accept nothing else", () => {
    fc.assert(
      fc.property(arbReachableSnapshot, (s) => {
        fc.pre(canClaim(s));
        expect(isTradable(s)).toBe(false);
        expect(canAddLiquidity(s)).toBe(false);
        expect(canMintSets(s)).toBe(false);
        expect(isResolvable(s)).toBe(false);
      }),
    );
  });
});

describe("gating helpers: fuzzed against an independent oracle of the contract's rules", () => {
  it("property: canAddLiquidity === the Solidity gate, everywhere", () => {
    fc.assert(
      fc.property(arbReachableSnapshot, (s) => {
        expect(canAddLiquidity(s)).toBe(oracleCanAddLiquidity(s));
      }),
    );
  });

  it("property: isTradable === the Solidity gate, everywhere", () => {
    fc.assert(
      fc.property(arbReachableSnapshot, (s) => {
        expect(isTradable(s)).toBe(oracleIsTradable(s));
      }),
    );
  });

  it("property: canMintSets === the Solidity gate, everywhere", () => {
    fc.assert(
      fc.property(arbReachableSnapshot, (s) => {
        expect(canMintSets(s)).toBe(oracleCanMintSets(s));
      }),
    );
  });

  it("property: isResolvable === the Solidity gate, everywhere", () => {
    fc.assert(
      fc.property(arbReachableSnapshot, (s) => {
        expect(isResolvable(s)).toBe(oracleIsResolvable(s));
      }),
    );
  });
});

describe("display helpers: fuzzed bounds", () => {
  it("property: displayedProbability is null or within [0, 1]; resolved pins to the winner", () => {
    fc.assert(
      fc.property(arbReachableSnapshot, (s) => {
        const p = displayedProbability(s);
        if (s.resolved) {
          expect(p).toBe(s.yesWon ? 1 : 0);
        } else if (p !== null) {
          expect(p).toBeGreaterThanOrEqual(0);
          expect(p).toBeLessThanOrEqual(1);
        }
      }),
    );
  });

  it("property: a position is never valued below 0 or above its token count", () => {
    const arbBalance = fc.bigInt({ min: 0n, max: 10n ** 27n });
    fc.assert(
      fc.property(arbReachableSnapshot, arbBalance, arbBalance, (s, yesBalance, noBalance) => {
        const v = positionValueFloat(s, { yesBalance, noBalance });
        const ceiling = Number(yesBalance + noBalance) / 1e18;
        expect(v).toBeGreaterThanOrEqual(0);
        expect(v).toBeLessThanOrEqual(ceiling * (1 + 1e-9) + 1e-9);
      }),
    );
  });
});

describe("toRoundSnapshot: fuzzed decoder round-trip", () => {
  const arbBool = fc.boolean();
  const arbU256 = fc.bigInt({ min: 0n, max: 2n ** 256n - 1n });

  it("property: every tuple field lands in the right snapshot field, verbatim", () => {
    fc.assert(
      fc.property(
        fc.tuple(arbBool, arbBool, arbBool, arbBool, arbU256, arbU256, arbBool, arbBool),
        fc.tuple(arbU256, arbU256, arbU256, arbU256, arbU256, arbU256, arbU256),
        arbU256,
        arbU256,
        arbU256,
        (state, pool, roundId, gameRoundNum, prevRoundCount) => {
          const s = toRoundSnapshot({
            seriesAddress: SERIES,
            roundId,
            state: state as RoundStateTuple,
            pool: pool as PoolTuple,
            gameRoundNum,
            prevRoundCount,
            cstAddress: CST,
            gameAddress: GAME,
          });
          expect(s.initialized).toBe(state[0]);
          expect(s.thresholdKnown).toBe(state[1]);
          expect(s.resolved).toBe(state[2]);
          expect(s.yesWon).toBe(state[3]);
          expect(s.threshold).toBe(state[4]);
          expect(s.currentCount).toBe(state[5]);
          expect(s.roundId).toBe(roundId);
          expect(s.gameRoundNum).toBe(gameRoundNum);
          expect(s.prevRoundCount).toBe(prevRoundCount);
          expect(s.pool).toEqual({
            reserveYes: pool[0],
            reserveNo: pool[1],
            totalShares: pool[2],
            accFeePerShare: pool[3],
            feeReserve: pool[4],
            feeWeight: pool[5],
          });
          expect(s.seriesAddress).toBe(SERIES);
          expect(s.cstAddress).toBe(CST);
          expect(s.gameAddress).toBe(GAME);
        },
      ),
    );
  });
});

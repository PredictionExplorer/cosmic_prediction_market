import fc from "fast-check";
import { describe, expect, it } from "vitest";
import vectors from "@/test/fixtures/contract-vectors.json";
import {
  aggregateProbabilityFloat,
  applyBet,
  bestTier,
  BPS,
  buyAmount,
  ceilDiv,
  claimValue,
  DEAD_SHARES,
  EMPTY_POOL,
  entryProbability,
  joinPool,
  minTokensOutForSlippage,
  ONE,
  openPool,
  pendingFees,
  poolIsTradable,
  positionValueAtProbability,
  probabilityFloat,
  quoteBet,
  removeLiquidity,
  takeFee,
  type PoolState,
  type TierPool,
} from "./math";

const LIQ = 10_000n * ONE;

/** A funded 50/50 pool like the local sandbox seeds. */
function pool(overrides: Partial<PoolState> = {}): PoolState {
  return {
    reserveYes: LIQ,
    reserveNo: LIQ,
    totalShares: LIQ,
    accFeePerShare: 0n,
    feeReserve: 0n,
    ...overrides,
  };
}

const arbAmount = fc.bigInt({ min: 1n, max: 10n ** 24n }); // up to 1M CST
const arbFee = fc.bigInt({ min: 1n, max: 1_000n });
const arbReserve = fc.bigInt({ min: ONE / 1000n, max: 10n ** 27n });
const arbProb = fc.bigInt({ min: 100n, max: 9_900n });
const arbLiquidity = fc.bigInt({ min: 10n ** 15n, max: 10n ** 24n });

describe("ceilDiv", () => {
  it("matches Solidity's _ceilDiv on exact and inexact divisions", () => {
    expect(ceilDiv(10n, 5n)).toBe(2n);
    expect(ceilDiv(11n, 5n)).toBe(3n);
    expect(ceilDiv(0n, 5n)).toBe(0n);
  });

  it("rejects non-positive divisors and negative dividends", () => {
    expect(() => ceilDiv(1n, 0n)).toThrow();
    expect(() => ceilDiv(-1n, 2n)).toThrow();
  });

  it("property: result is the smallest q with q*b >= a", () => {
    fc.assert(
      fc.property(fc.bigInt({ min: 0n, max: 10n ** 30n }), fc.bigInt({ min: 1n, max: 10n ** 20n }), (a, b) => {
        const q = ceilDiv(a, b);
        expect(q * b >= a).toBe(true);
        expect((q - 1n) * b < a || q === 0n).toBe(true);
      }),
    );
  });
});

describe("takeFee", () => {
  it("property: fee + net === amount, fee rounds down", () => {
    fc.assert(
      fc.property(arbAmount, arbFee, (amount, feeBps) => {
        const { fee, net } = takeFee(amount, feeBps);
        expect(fee + net).toBe(amount);
        expect(fee).toBe((amount * feeBps) / BPS);
      }),
    );
  });
});

describe("buyAmount / quoteBet / applyBet", () => {
  it("property: the pool never loses — k never decreases, reserves never empty", () => {
    fc.assert(
      fc.property(arbAmount, arbFee, arbReserve, arbReserve, (cstIn, feeBps, rY, rN) => {
        const p = pool({ reserveYes: rY, reserveNo: rN });
        const after = applyBet("yes", p, cstIn, feeBps).pool;
        expect(after.reserveYes * after.reserveNo >= rY * rN).toBe(true);
        expect(after.reserveYes >= 1n).toBe(true);
        expect(after.reserveNo >= 1n).toBe(true);
      }),
    );
  });

  it("property: quote equals execution for both sides", () => {
    fc.assert(
      fc.property(arbAmount, arbFee, arbReserve, arbReserve, (cstIn, feeBps, rY, rN) => {
        const p = pool({ reserveYes: rY, reserveNo: rN });
        expect(quoteBet("yes", p, cstIn, feeBps)).toBe(applyBet("yes", p, cstIn, feeBps).tokensOut);
        expect(quoteBet("no", p, cstIn, feeBps)).toBe(applyBet("no", p, cstIn, feeBps).tokensOut);
      }),
    );
  });

  it("property: tokensOut is at least net and below net + reserveOut", () => {
    fc.assert(
      fc.property(arbAmount, arbFee, arbReserve, arbReserve, (cstIn, feeBps, rY, rN) => {
        const p = pool({ reserveYes: rY, reserveNo: rN });
        const { net } = takeFee(cstIn, feeBps);
        const out = applyBet("yes", p, cstIn, feeBps).tokensOut;
        expect(out >= net).toBe(true);
        expect(out < net + rY).toBe(true);
      }),
    );
  });

  it("property: betting YES raises P(YES); betting NO lowers it", () => {
    fc.assert(
      fc.property(fc.bigInt({ min: ONE, max: 10n ** 23n }), arbFee, (cstIn, feeBps) => {
        const p = pool();
        const pBefore = probabilityFloat(p) as number;
        const afterYes = applyBet("yes", p, cstIn, feeBps).pool;
        const afterNo = applyBet("no", p, cstIn, feeBps).pool;
        expect(probabilityFloat(afterYes) as number).toBeGreaterThan(pBefore);
        expect(probabilityFloat(afterNo) as number).toBeLessThan(pBefore);
      }),
    );
  });

  it("property: fee escrow and accumulator advance exactly", () => {
    fc.assert(
      fc.property(arbAmount, arbFee, (cstIn, feeBps) => {
        const p = pool();
        const { fee } = takeFee(cstIn, feeBps);
        const after = applyBet("yes", p, cstIn, feeBps).pool;
        expect(after.feeReserve).toBe(fee);
        expect(after.accFeePerShare).toBe((fee * ONE) / p.totalShares);
      }),
    );
  });

  it("quotes 0 for unfunded or drained pools", () => {
    expect(quoteBet("yes", EMPTY_POOL, ONE, 100n)).toBe(0n);
    expect(quoteBet("no", pool({ reserveYes: 0n }), ONE, 100n)).toBe(0n);
    expect(poolIsTradable(EMPTY_POOL)).toBe(false);
  });
});

describe("bestTier routing", () => {
  const arbTierPools = fc
    .tuple(
      fc.bigInt({ min: 10n ** 15n, max: 10n ** 23n }),
      fc.bigInt({ min: 10n ** 15n, max: 10n ** 23n }),
      fc.bigInt({ min: 10n ** 15n, max: 10n ** 23n }),
      fc.bigInt({ min: 10n ** 13n, max: 10n ** 23n }),
      fc.bigInt({ min: 10n ** 13n, max: 10n ** 23n }),
      fc.bigInt({ min: 10n ** 13n, max: 10n ** 23n }),
    )
    .map(([y1, y2, y3, n1, n2, n3]): TierPool[] => [
      { feeBps: 100, pool: pool({ reserveYes: y1, reserveNo: n1 }) },
      { feeBps: 200, pool: pool({ reserveYes: y2, reserveNo: n2 }) },
      { feeBps: 500, pool: pool({ reserveYes: y3, reserveNo: n3 }) },
    ]);

  it("property: routed output beats or matches every individual tier", () => {
    fc.assert(
      fc.property(arbTierPools, arbAmount, fc.boolean(), (pools, cstIn, yes) => {
        const side = yes ? "yes" : "no";
        const best = bestTier(side, pools, cstIn);
        expect(best).not.toBeNull();
        for (const { feeBps, pool: p } of pools) {
          expect(best!.tokensOut >= quoteBet(side, p, cstIn, BigInt(feeBps))).toBe(true);
        }
      }),
    );
  });

  it("ties go to the lowest fee; identical pools route to the cheapest tier", () => {
    const pools: TierPool[] = [
      { feeBps: 500, pool: pool() },
      { feeBps: 100, pool: pool() },
      { feeBps: 200, pool: pool() },
    ];
    expect(bestTier("yes", pools, 100n * ONE)?.feeBps).toBe(100);
  });

  it("skips unfunded pools and returns null when nothing is funded", () => {
    const pools: TierPool[] = [
      { feeBps: 100, pool: EMPTY_POOL },
      { feeBps: 200, pool: pool() },
    ];
    expect(bestTier("yes", pools, ONE)?.feeBps).toBe(200);
    expect(bestTier("yes", [{ feeBps: 100, pool: EMPTY_POOL }], ONE)).toBeNull();
  });
});

describe("openPool", () => {
  it("property: conserves both token sides exactly and prices at the request", () => {
    fc.assert(
      fc.property(arbLiquidity, arbProb, (cstIn, prob) => {
        const { pool: p, sharesOut, excessYes, excessNo } = openPool(cstIn, prob);
        expect(p.reserveYes + excessYes).toBe(cstIn);
        expect(p.reserveNo + excessNo).toBe(cstIn);
        expect(sharesOut).toBe(cstIn - DEAD_SHARES);
        expect(p.totalShares).toBe(cstIn);
        const implied = probabilityFloat(p) as number;
        expect(Math.abs(implied - Number(prob) / 10_000)).toBeLessThan(0.0002);
      }),
    );
  });

  it("rejects deposits below the minimum and odds outside [1%, 99%]", () => {
    expect(() => openPool(10n ** 15n - 1n, 5_000n)).toThrow(/minimum/);
    expect(() => openPool(LIQ, 99n)).toThrow(/probability/);
    expect(() => openPool(LIQ, 9_901n)).toThrow(/probability/);
  });
});

describe("joinPool", () => {
  const arbSkewedPool = fc
    .tuple(arbLiquidity, arbProb, fc.bigInt({ min: 1n, max: 10n ** 23n }), fc.boolean(), arbFee)
    .map(([liq, prob, skew, skewYes, fee]) => {
      let p = openPool(liq, prob).pool;
      p = applyBet(skewYes ? "yes" : "no", p, skew, fee).pool;
      return p;
    });

  it("property: joining never moves the price and conserves tokens", () => {
    fc.assert(
      fc.property(arbSkewedPool, arbAmount, (p, cstIn) => {
        const result = joinPool(p, cstIn);
        if (result === null) return; // deposit too small to mint one share
        const before = probabilityFloat(p) as number;
        const after = probabilityFloat(result.pool) as number;
        expect(Math.abs(after - before)).toBeLessThan(0.0002);
        expect(result.depositYes + result.excessYes).toBe(cstIn);
        expect(result.depositNo + result.excessNo).toBe(cstIn);
      }),
    );
  });

  it("property: a joiner's instant pro-rata claim never exceeds their deposit", () => {
    fc.assert(
      fc.property(arbSkewedPool, arbAmount, (p, cstIn) => {
        const result = joinPool(p, cstIn);
        if (result === null) return;
        const claimYes = (result.pool.reserveYes * result.sharesOut) / result.pool.totalShares;
        const claimNo = (result.pool.reserveNo * result.sharesOut) / result.pool.totalShares;
        expect(claimYes <= result.depositYes).toBe(true);
        expect(claimNo <= result.depositNo).toBe(true);
      }),
    );
  });

  it("returns null for drained pools and dust deposits", () => {
    expect(joinPool(pool({ reserveYes: 0n, reserveNo: 100n }), ONE)).toBeNull();
    // 1 wei into a pool whose max reserve exceeds totalShares by > 1x.
    expect(joinPool(pool({ reserveYes: LIQ * 3n, totalShares: LIQ / 2n }), 1n)).toBeNull();
  });
});

describe("removeLiquidity", () => {
  it("property: add-then-remove can never pay out more than went in", () => {
    fc.assert(
      fc.property(
        fc.bigInt({ min: 1n, max: 10n ** 23n }),
        fc.boolean(),
        arbFee,
        fc.bigInt({ min: 10n ** 6n, max: 10n ** 24n }),
        (skew, skewYes, fee, add) => {
          let p = openPool(LIQ, 5_000n).pool;
          p = applyBet(skewYes ? "yes" : "no", p, skew, fee).pool;
          const joined = joinPool(p, add);
          if (joined === null) return;
          const { yesOut, noOut } = removeLiquidity(joined.pool, joined.sharesOut);
          const yesTotal = yesOut + joined.excessYes;
          const noTotal = noOut + joined.excessNo;
          // Even valuing every returned token at its 1 CST ceiling.
          expect(yesTotal <= add).toBe(true);
          expect(noTotal <= add).toBe(true);
        },
      ),
    );
  });

  it("property: withdrawals are pro-rata within rounding", () => {
    fc.assert(
      fc.property(arbReserve, arbReserve, fc.bigInt({ min: 1n, max: 10n ** 24n }), (rY, rN, shares) => {
        const total = 10n ** 24n;
        const p = pool({ reserveYes: rY, reserveNo: rN, totalShares: total });
        const { yesOut, noOut } = removeLiquidity(p, shares);
        expect(yesOut).toBe((rY * shares) / total);
        expect(noOut).toBe((rN * shares) / total);
      }),
    );
  });
});

describe("fees and positions", () => {
  it("pendingFees mirrors the MasterChef formula", () => {
    expect(pendingFees(100n * ONE, ONE / 100n, 0n)).toBe(ONE);
    expect(pendingFees(100n * ONE, ONE / 100n, ONE / 2n)).toBe(ONE / 2n);
  });

  it("claimValue pays the winning side 1:1 and the losing side nothing", () => {
    expect(claimValue(7n * ONE, 3n * ONE, true)).toBe(7n * ONE);
    expect(claimValue(7n * ONE, 3n * ONE, false)).toBe(3n * ONE);
  });

  it("positionValueAtProbability interpolates between the two claims", () => {
    expect(positionValueAtProbability(10n * ONE, 0n, 0.5)).toBeCloseTo(5);
    expect(positionValueAtProbability(0n, 10n * ONE, 0.25)).toBeCloseTo(7.5);
  });

  it("entryProbability is cost per token", () => {
    expect(entryProbability(50n * ONE, 100n * ONE)).toBeCloseTo(0.5);
    expect(entryProbability(ONE, 0n)).toBeNull();
  });

  it("minTokensOutForSlippage rounds down and validates its input", () => {
    expect(minTokensOutForSlippage(10_000n, 50)).toBe(9_950n);
    expect(() => minTokensOutForSlippage(1n, -1)).toThrow();
    expect(() => minTokensOutForSlippage(1n, 10_001)).toThrow();
  });

  it("aggregateProbabilityFloat weights pools by their liquidity", () => {
    const pools: TierPool[] = [
      { feeBps: 100, pool: pool({ reserveYes: 100n * ONE, reserveNo: 100n * ONE }) },
      { feeBps: 200, pool: pool({ reserveYes: 0n, reserveNo: 200n * ONE }) },
    ];
    // (100 + 200) NO over (200 + 200) total = 0.75.
    expect(aggregateProbabilityFloat(pools)).toBeCloseTo(0.75);
    expect(aggregateProbabilityFloat([])).toBeNull();
  });
});

// ---------------------------------------------------------------------
// Differential tests: every number produced by the REAL contract
// (script/GenerateVectors.s.sol) must match this library bit-for-bit.
// ---------------------------------------------------------------------

describe("differential vectors from the contract", () => {
  it(`buyAmount matches the contract on ${vectors.buyAmount.length} magnitude-swept cases`, () => {
    for (const v of vectors.buyAmount) {
      expect(buyAmount(BigInt(v.reserveOut), BigInt(v.reserveIn), BigInt(v.net))).toBe(BigInt(v.tokensOut));
    }
  });

  it(`replays ${vectors.flows.length} executed open→bet→join→remove flows exactly`, () => {
    for (const v of vectors.flows) {
      const feeBps = BigInt(v.tier);

      // Open.
      const opened = openPool(BigInt(v.liq), BigInt(v.probBps));
      expect(opened.pool.reserveYes).toBe(BigInt(v.openReserveYes));
      expect(opened.pool.reserveNo).toBe(BigInt(v.openReserveNo));
      expect(opened.pool.totalShares).toBe(BigInt(v.openTotalShares));
      expect(opened.sharesOut).toBe(BigInt(v.openShares));

      // Bet.
      const bet = applyBet(v.betYes ? "yes" : "no", opened.pool, BigInt(v.betAmount), feeBps);
      expect(bet.tokensOut).toBe(BigInt(v.betOut));
      expect(bet.pool.reserveYes).toBe(BigInt(v.postBetReserveYes));
      expect(bet.pool.reserveNo).toBe(BigInt(v.postBetReserveNo));
      expect(bet.pool.accFeePerShare).toBe(BigInt(v.postBetAccFeePerShare));
      expect(bet.pool.feeReserve).toBe(BigInt(v.postBetFeeReserve));

      // Join.
      const joined = joinPool(bet.pool, BigInt(v.joinAmount));
      expect(joined).not.toBeNull();
      expect(joined!.sharesOut).toBe(BigInt(v.joinShares));
      expect(joined!.pool.reserveYes).toBe(BigInt(v.postJoinReserveYes));
      expect(joined!.pool.reserveNo).toBe(BigInt(v.postJoinReserveNo));
      expect(joined!.pool.totalShares).toBe(BigInt(v.postJoinTotalShares));
      // The actor's cumulative outcome balances after the join: excess from
      // the open, plus the bet's payout, plus excess from the join.
      const betYesTokens = v.betYes ? bet.tokensOut : 0n;
      const betNoTokens = v.betYes ? 0n : bet.tokensOut;
      expect(opened.excessYes + betYesTokens + joined!.excessYes).toBe(BigInt(v.balanceYesAfterJoin));
      expect(opened.excessNo + betNoTokens + joined!.excessNo).toBe(BigInt(v.balanceNoAfterJoin));

      // Remove.
      const removed = removeLiquidity(joined!.pool, BigInt(v.removeShares));
      expect(removed.yesOut).toBe(BigInt(v.removeYes));
      expect(removed.noOut).toBe(BigInt(v.removeNo));
      expect(removed.pool.reserveYes).toBe(BigInt(v.postRemoveReserveYes));
      expect(removed.pool.reserveNo).toBe(BigInt(v.postRemoveReserveNo));
      expect(removed.pool.totalShares).toBe(BigInt(v.postRemoveTotalShares));

      // Fee accounting through the whole flow, to the wei. The single actor
      // opened the pool (feeDebt 0), earned the bet's fee, then had it paid
      // out automatically when joining (which also reset their debt), so the
      // remove pays no further fees.
      const pendingAtJoin = pendingFees(BigInt(v.openShares), BigInt(v.postBetAccFeePerShare), 0n);
      expect(BigInt(v.postJoinFeeReserve)).toBe(BigInt(v.postBetFeeReserve) - pendingAtJoin);
      expect(BigInt(v.removeFees)).toBe(0n);
      expect(BigInt(v.postRemoveFeeReserve)).toBe(BigInt(v.postJoinFeeReserve));
      expect(BigInt(v.postRemoveAccFeePerShare)).toBe(BigInt(v.postBetAccFeePerShare));
    }
  });
});

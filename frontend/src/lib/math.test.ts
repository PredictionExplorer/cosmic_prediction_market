import fc from "fast-check";
import { describe, expect, it } from "vitest";
import {
  applyBet,
  BPS,
  breakEvenCount,
  ceilDiv,
  claimValue,
  entryCount,
  invertBet,
  minTokensOutForSlippage,
  ONE,
  payoutPerHigherFor,
  positionValueAt,
  predictedCount,
  predictedCountFloat,
  quoteBet,
  rangeFraction,
  takeFee,
  type PoolState,
} from "./math";

// Mirrors the deploy script defaults: range 200–1200 in several tests below,
// and the reference values are cross-checked against the Foundry unit tests.
const RANGE = { minCount: 200n, maxCount: 1_200n };
const LIQ = 10_000n * ONE;
const POOL: PoolState = { reserveHigher: LIQ, reserveLower: LIQ };
const FEE = 100n; // 1%, like the deploy default

const arbAmount = fc.bigInt({ min: 1n, max: 10n ** 24n }); // up to 1M CST
const arbFee = fc.bigInt({ min: 0n, max: 1_000n });
const arbReserve = fc.bigInt({ min: ONE / 1000n, max: 10n ** 27n });

describe("ceilDiv", () => {
  it("matches Solidity's _ceilDiv on exact and inexact divisions", () => {
    expect(ceilDiv(10n, 5n)).toBe(2n);
    expect(ceilDiv(11n, 5n)).toBe(3n);
    expect(ceilDiv(0n, 5n)).toBe(0n);
    expect(ceilDiv(1n, 1n)).toBe(1n);
  });

  it("rejects non-positive divisors and negative dividends", () => {
    expect(() => ceilDiv(1n, 0n)).toThrow();
    expect(() => ceilDiv(-1n, 2n)).toThrow();
  });

  it("property: result is the smallest q with q*b >= a", () => {
    fc.assert(
      fc.property(
        fc.bigInt({ min: 0n, max: 10n ** 30n }),
        fc.bigInt({ min: 1n, max: 10n ** 20n }),
        (a, b) => {
          const q = ceilDiv(a, b);
          expect(q * b >= a).toBe(true);
          expect((q - 1n) * b < a || q === 0n).toBe(true);
        },
      ),
    );
  });
});

describe("takeFee", () => {
  it("splits amount into fee and net exactly", () => {
    const { fee, net } = takeFee(1_000n * ONE, 100n);
    expect(fee).toBe(10n * ONE);
    expect(net).toBe(990n * ONE);
  });

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
  it("reproduces the contract's reference bet from the Foundry tests", () => {
    // test_betHigherMovesPredictionUp: 5000 CST at 1% fee into 10k/10k pool.
    const result = applyBet("higher", POOL, 5_000n * ONE, FEE);
    // Buying below max price always yields more tokens than the net CST spent.
    expect(result.tokensOut > 4_950n * ONE).toBe(true);
    expect(result.fee).toBe(50n * ONE);
    // The prediction must rise above the midpoint (700).
    const predicted = predictedCount(RANGE, result.pool);
    expect(predicted > 700n).toBe(true);
  });

  it("quoteBet matches applyBet's tokensOut for both sides", () => {
    fc.assert(
      fc.property(arbAmount, arbFee, arbReserve, arbReserve, (cstIn, feeBps, rh, rl) => {
        const pool = { reserveHigher: rh, reserveLower: rl };
        expect(quoteBet("higher", pool, cstIn, feeBps)).toBe(applyBet("higher", pool, cstIn, feeBps).tokensOut);
        expect(quoteBet("lower", pool, cstIn, feeBps)).toBe(applyBet("lower", pool, cstIn, feeBps).tokensOut);
      }),
    );
  });

  it("property: pool constant product k never decreases (pool never loses)", () => {
    fc.assert(
      fc.property(arbAmount, arbFee, arbReserve, arbReserve, (cstIn, feeBps, rh, rl) => {
        const pool = { reserveHigher: rh, reserveLower: rl };
        const after = applyBet("higher", pool, cstIn, feeBps).pool;
        expect(after.reserveHigher * after.reserveLower >= rh * rl).toBe(true);
      }),
    );
  });

  it("property: tokensOut is between net (min) and net + reserveOut (max)", () => {
    fc.assert(
      fc.property(arbAmount, arbFee, arbReserve, arbReserve, (cstIn, feeBps, rh, rl) => {
        const pool = { reserveHigher: rh, reserveLower: rl };
        const { net } = takeFee(cstIn, feeBps);
        const out = applyBet("higher", pool, cstIn, feeBps).tokensOut;
        expect(out >= net).toBe(true);
        expect(out < net + rh).toBe(true);
      }),
    );
  });

  it("property: higher/lower are exact mirrors of each other", () => {
    fc.assert(
      fc.property(arbAmount, arbFee, arbReserve, arbReserve, (cstIn, feeBps, rh, rl) => {
        const pool = { reserveHigher: rh, reserveLower: rl };
        const mirror = { reserveHigher: rl, reserveLower: rh };
        const a = applyBet("higher", pool, cstIn, feeBps);
        const b = applyBet("lower", mirror, cstIn, feeBps);
        expect(a.tokensOut).toBe(b.tokensOut);
        expect(a.pool.reserveHigher).toBe(b.pool.reserveLower);
        expect(a.pool.reserveLower).toBe(b.pool.reserveHigher);
      }),
    );
  });

  it("mirrors the Foundry split-bet fuzz test exactly (balanced pool, 1% fee, ±4 wei)", () => {
    // Same domain and tolerance as testFuzz_splitBetEquivalentToSingleBet.
    fc.assert(
      fc.property(
        fc.bigInt({ min: ONE, max: 100_000n * ONE }),
        fc.bigInt({ min: ONE, max: 100_000n * ONE }),
        (a, b) => {
          const first = applyBet("higher", POOL, a, FEE);
          const second = applyBet("higher", first.pool, b, FEE);
          const split = first.tokensOut + second.tokensOut;
          const whole = applyBet("higher", POOL, a + b, FEE).tokensOut;
          const diff = split > whole ? split - whole : whole - split;
          expect(diff <= 4n).toBe(true);
        },
      ),
    );
  });

  it("property: splitting a bet is path-independent within amplified rounding", () => {
    // The ±1 wei fee-flooring wobble is amplified by the marginal token price,
    // which is bounded by reserveOut/reserveIn; plus a couple of ceilDiv weis.
    fc.assert(
      fc.property(
        fc.bigInt({ min: 2n, max: 10n ** 24n }),
        arbFee,
        arbReserve,
        arbReserve,
        (cstIn, feeBps, rh, rl) => {
          const pool = { reserveHigher: rh, reserveLower: rl };
          const whole = applyBet("higher", pool, cstIn, feeBps).tokensOut;
          const half = cstIn / 2n;
          const first = applyBet("higher", pool, half, feeBps);
          const second = applyBet("higher", first.pool, cstIn - half, feeBps);
          const split = first.tokensOut + second.tokensOut;
          const diff = split > whole ? split - whole : whole - split;
          const bound = 4n + ceilDiv(rh, rl);
          expect(diff <= bound).toBe(true);
        },
      ),
    );
  });
});

describe("invertBet", () => {
  it("property: exactly inverts applyBet (roundtrip through any bet)", () => {
    fc.assert(
      fc.property(
        arbAmount,
        arbFee,
        arbReserve,
        arbReserve,
        fc.constantFrom("higher" as const, "lower" as const),
        (cstIn, feeBps, rh, rl, side) => {
          const before = { reserveHigher: rh, reserveLower: rl };
          const { tokensOut, pool: after } = applyBet(side, before, cstIn, feeBps);
          const recovered = invertBet(side, after, cstIn, tokensOut, feeBps);
          expect(recovered.reserveHigher).toBe(before.reserveHigher);
          expect(recovered.reserveLower).toBe(before.reserveLower);
        },
      ),
    );
  });
});

describe("predictedCount", () => {
  it("is the midpoint for a balanced pool", () => {
    expect(predictedCount(RANGE, POOL)).toBe(700n);
    expect(predictedCountFloat(RANGE, POOL)).toBeCloseTo(700, 6);
  });

  it("moves toward maxCount when LOWER reserve dominates", () => {
    // More LOWER in the pool ⇒ HIGHER is pricier ⇒ market predicts higher count.
    const pool = { reserveHigher: 1n * ONE, reserveLower: 99n * ONE };
    expect(predictedCount(RANGE, pool)).toBe(200n + (1_000n * 99n) / 100n);
  });

  it("property: prediction always stays within [minCount, maxCount]", () => {
    fc.assert(
      fc.property(arbReserve, arbReserve, (rh, rl) => {
        const p = predictedCount(RANGE, { reserveHigher: rh, reserveLower: rl });
        expect(p >= RANGE.minCount && p <= RANGE.maxCount).toBe(true);
        const f = predictedCountFloat(RANGE, { reserveHigher: rh, reserveLower: rl });
        expect(f).toBeGreaterThanOrEqual(Number(RANGE.minCount));
        expect(f).toBeLessThanOrEqual(Number(RANGE.maxCount));
      }),
    );
  });

  it("property: betting higher never lowers the prediction", () => {
    fc.assert(
      fc.property(arbAmount, arbFee, arbReserve, arbReserve, (cstIn, feeBps, rh, rl) => {
        const pool = { reserveHigher: rh, reserveLower: rl };
        const before = predictedCountFloat(RANGE, pool);
        const after = predictedCountFloat(RANGE, applyBet("higher", pool, cstIn, feeBps).pool);
        expect(after).toBeGreaterThanOrEqual(before - 1e-6);
      }),
    );
  });
});

describe("rangeFraction", () => {
  it("clamps into [0,1] and maps the midpoint to 0.5", () => {
    expect(rangeFraction(RANGE, 700)).toBeCloseTo(0.5);
    expect(rangeFraction(RANGE, 0)).toBe(0);
    expect(rangeFraction(RANGE, 99_999)).toBe(1);
  });

  it("degenerate range returns 0 instead of dividing by zero", () => {
    expect(rangeFraction({ minCount: 5n, maxCount: 5n }, 5)).toBe(0);
  });
});

describe("payoutPerHigherFor / claimValue / positionValueAt", () => {
  it("reproduces the contract's reference resolution (count=1000 in 200–1200 ⇒ 0.8)", () => {
    expect(payoutPerHigherFor(RANGE, 1_000n)).toBe((8n * ONE) / 10n);
  });

  it("clamps counts outside the range", () => {
    expect(payoutPerHigherFor(RANGE, 10n)).toBe(0n);
    expect(payoutPerHigherFor(RANGE, 50_000n)).toBe(ONE);
  });

  it("boundary counts pay exactly 0 and exactly 1", () => {
    expect(payoutPerHigherFor(RANGE, RANGE.minCount)).toBe(0n);
    expect(payoutPerHigherFor(RANGE, RANGE.maxCount)).toBe(ONE);
  });

  it("property: a complete set (1 HIGHER + 1 LOWER) is always worth exactly 1 CST", () => {
    fc.assert(
      fc.property(fc.bigInt({ min: 0n, max: 10n ** 13n }), fc.bigInt({ min: 1n, max: 10n ** 24n }), (count, amount) => {
        const rate = payoutPerHigherFor(RANGE, count);
        expect(claimValue(amount, amount, rate)).toBe(amount);
      }),
    );
  });

  it("property: claim value is monotone in the final count for a HIGHER position", () => {
    fc.assert(
      fc.property(
        fc.bigInt({ min: 0n, max: 2_000n }),
        fc.bigInt({ min: 0n, max: 2_000n }),
        fc.bigInt({ min: 1n, max: 10n ** 24n }),
        (c1, c2, tokens) => {
          const [lo, hi] = c1 <= c2 ? [c1, c2] : [c2, c1];
          const vLo = positionValueAt(RANGE, tokens, 0n, lo);
          const vHi = positionValueAt(RANGE, tokens, 0n, hi);
          expect(vHi >= vLo).toBe(true);
        },
      ),
    );
  });
});

describe("breakEvenCount / entryCount", () => {
  it("pure HIGHER position breaks even where payout*tokens = cost", () => {
    // 1000 HIGHER bought for 800 CST ⇒ f* = 0.8 ⇒ count 1000 in [200, 1200].
    const be = breakEvenCount(RANGE, 1_000n * ONE, 0n, 800n * ONE);
    expect(be).toBeCloseTo(1_000, 6);
  });

  it("pure LOWER position mirrors it", () => {
    const be = breakEvenCount(RANGE, 0n, 1_000n * ONE, 800n * ONE);
    // payout = tokens*(1-f) = cost ⇒ f = 0.2 ⇒ count 400.
    expect(be).toBeCloseTo(400, 6);
  });

  it("balanced position has no break-even (value independent of count)", () => {
    expect(breakEvenCount(RANGE, 5n, 5n, 5n)).toBeNull();
  });

  it("entryCount for a bet is the prediction the trader effectively bought at", () => {
    const { tokensOut } = applyBet("higher", POOL, 1_000n * ONE, 0n);
    const entry = entryCount(RANGE, "higher", 1_000n * ONE, tokensOut);
    // Entry must sit above the pre-trade midpoint (700) but within range.
    expect(entry).not.toBeNull();
    expect(entry!).toBeGreaterThan(700);
    expect(entry!).toBeLessThan(1_200);
  });

  it("entryCount is null for zero tokensOut", () => {
    expect(entryCount(RANGE, "higher", 1n, 0n)).toBeNull();
  });

  it("property: at the break-even count the position value equals the cost (within rounding)", () => {
    fc.assert(
      fc.property(
        fc.bigInt({ min: ONE, max: 10n ** 24n }),
        fc.bigInt({ min: 1n, max: 10n ** 24n }),
        (tokens, cost) => {
          fc.pre(cost < tokens); // pure HIGHER break-even exists inside [0,1] only if cost < tokens
          const be = breakEvenCount(RANGE, tokens, 0n, cost);
          expect(be).not.toBeNull();
          const value = positionValueAt(RANGE, tokens, 0n, BigInt(Math.round(be!)));
          const tolerance = tokens / 500n + ONE; // one count step of value + rounding
          const diff = value > cost ? value - cost : cost - value;
          expect(diff <= tolerance).toBe(true);
        },
      ),
    );
  });
});

describe("minTokensOutForSlippage", () => {
  it("applies bps tolerance rounding down", () => {
    expect(minTokensOutForSlippage(10_000n, 50)).toBe(9_950n);
    expect(minTokensOutForSlippage(3n, 1)).toBe(2n);
    expect(minTokensOutForSlippage(10_000n, 0)).toBe(10_000n);
  });

  it("rejects out-of-range tolerances", () => {
    expect(() => minTokensOutForSlippage(1n, -1)).toThrow();
    expect(() => minTokensOutForSlippage(1n, 10_001)).toThrow();
  });

  it("property: result is always <= quoted and >= quoted*(1-bps/10000)-1", () => {
    fc.assert(
      fc.property(arbAmount, fc.integer({ min: 0, max: 10_000 }), (quoted, bps) => {
        const min = minTokensOutForSlippage(quoted, bps);
        expect(min <= quoted).toBe(true);
        const exact = (quoted * (BPS - BigInt(bps))) / BPS;
        expect(min).toBe(exact);
      }),
    );
  });
});

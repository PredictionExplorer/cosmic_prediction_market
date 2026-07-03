/**
 * Pure bigint math mirroring `GestureMarket.sol` exactly (floor division,
 * `ceilDiv` rounding in the pool's favor). Keeping this in sync with the
 * contract lets the UI quote bets, price positions, and replay history
 * instantly without extra RPC calls — and lets us property-test the lot.
 */

export const ONE = 10n ** 18n;
export const BPS = 10_000n;
export const MAX_FEE_BPS = 1_000n;

export interface PoolState {
  readonly reserveHigher: bigint;
  readonly reserveLower: bigint;
}

export interface MarketRange {
  readonly minCount: bigint;
  readonly maxCount: bigint;
}

export type BetSide = "higher" | "lower";

export interface BetResult {
  /** Outcome tokens received. */
  readonly tokensOut: bigint;
  /** Fee taken off the top, accrues to the market creator. */
  readonly fee: bigint;
  /** CST that actually entered the pool (`cstIn - fee`). */
  readonly net: bigint;
  /** Pool state after the bet. */
  readonly pool: PoolState;
}

/** Solidity-style ceiling division for non-negative operands. */
export function ceilDiv(a: bigint, b: bigint): bigint {
  if (b <= 0n) throw new Error("ceilDiv: divisor must be positive");
  if (a < 0n) throw new Error("ceilDiv: negative dividend");
  return (a + b - 1n) / b;
}

/** Mirrors `_takeFee`: fee rounds down, so `net` rounds up in the user's favor. */
export function takeFee(cstIn: bigint, feeBps: bigint): { fee: bigint; net: bigint } {
  const fee = (cstIn * feeBps) / BPS;
  return { fee, net: cstIn - fee };
}

/**
 * Mirrors `_buyAmount`: tokens received when `net` CST mints sets and the
 * unwanted side is swapped into the pool (x*y=k, rounded in the pool's favor).
 */
export function buyAmount(reserveOut: bigint, reserveIn: bigint, net: bigint): bigint {
  return net + reserveOut - ceilDiv(reserveOut * reserveIn, reserveIn + net);
}

/** Mirrors `quoteBetHigher` / `quoteBetLower`. */
export function quoteBet(side: BetSide, pool: PoolState, cstIn: bigint, feeBps: bigint): bigint {
  const { net } = takeFee(cstIn, feeBps);
  return side === "higher"
    ? buyAmount(pool.reserveHigher, pool.reserveLower, net)
    : buyAmount(pool.reserveLower, pool.reserveHigher, net);
}

/** Mirrors `betHigher` / `betLower`: quote plus the post-trade pool state. */
export function applyBet(side: BetSide, pool: PoolState, cstIn: bigint, feeBps: bigint): BetResult {
  const { fee, net } = takeFee(cstIn, feeBps);
  if (side === "higher") {
    const tokensOut = buyAmount(pool.reserveHigher, pool.reserveLower, net);
    return {
      tokensOut,
      fee,
      net,
      pool: {
        reserveHigher: pool.reserveHigher + net - tokensOut,
        reserveLower: pool.reserveLower + net,
      },
    };
  }
  const tokensOut = buyAmount(pool.reserveLower, pool.reserveHigher, net);
  return {
    tokensOut,
    fee,
    net,
    pool: {
      reserveHigher: pool.reserveHigher + net,
      reserveLower: pool.reserveLower + net - tokensOut,
    },
  };
}

/**
 * Exact inverse of `applyBet` given the recorded `cstIn`/`tokensOut` of a Bet
 * event: recovers the pool state *before* the bet. Used to rebuild the price
 * history backwards from current reserves (no archive node required).
 */
export function invertBet(
  side: BetSide,
  poolAfter: PoolState,
  cstIn: bigint,
  tokensOut: bigint,
  feeBps: bigint,
): PoolState {
  const { net } = takeFee(cstIn, feeBps);
  return side === "higher"
    ? {
        reserveHigher: poolAfter.reserveHigher - net + tokensOut,
        reserveLower: poolAfter.reserveLower - net,
      }
    : {
        reserveHigher: poolAfter.reserveHigher - net,
        reserveLower: poolAfter.reserveLower - net + tokensOut,
      };
}

/** Mirrors `predictedCount()` for a live pool (floor, like the contract). */
export function predictedCount(range: MarketRange, pool: PoolState): bigint {
  const total = pool.reserveHigher + pool.reserveLower;
  if (total === 0n) return range.minCount;
  return range.minCount + ((range.maxCount - range.minCount) * pool.reserveLower) / total;
}

/**
 * The prediction as a float with sub-integer precision, for smooth gauges and
 * charts (the contract's own getter floors to whole counts).
 */
export function predictedCountFloat(range: MarketRange, pool: PoolState): number {
  const total = pool.reserveHigher + pool.reserveLower;
  const span = range.maxCount - range.minCount;
  if (total === 0n) return Number(range.minCount);
  const SCALE = 1_000_000n;
  const scaled = (span * pool.reserveLower * SCALE) / total;
  return Number(range.minCount) + Number(scaled) / Number(SCALE);
}

/** Fraction of the way through the range, in [0, 1]. */
export function rangeFraction(range: MarketRange, count: number): number {
  const min = Number(range.minCount);
  const max = Number(range.maxCount);
  if (max <= min) return 0;
  return Math.min(1, Math.max(0, (count - min) / (max - min)));
}

/** Mirrors `resolve()`: clamps the final count and fixes the HIGHER payout rate. */
export function payoutPerHigherFor(range: MarketRange, finalCount: bigint): bigint {
  const clamped =
    finalCount < range.minCount ? range.minCount : finalCount > range.maxCount ? range.maxCount : finalCount;
  return ((clamped - range.minCount) * ONE) / (range.maxCount - range.minCount);
}

/** Mirrors `claim()`: CST paid for a token balance at a given payout rate. */
export function claimValue(higher: bigint, lower: bigint, payoutPerHigher: bigint): bigint {
  return (higher * payoutPerHigher + lower * (ONE - payoutPerHigher)) / ONE;
}

/** What a position would pay if the round ended at `finalCount` right now. */
export function positionValueAt(
  range: MarketRange,
  higher: bigint,
  lower: bigint,
  finalCount: bigint,
): bigint {
  return claimValue(higher, lower, payoutPerHigherFor(range, finalCount));
}

/**
 * The final count at which a position's payout equals `cost` (its break-even).
 * Payout is linear in the count between `lower` (at minCount) and `higher`
 * (at maxCount), so this solves one linear equation. Returns `null` when the
 * payout doesn't depend on the count (`higher === lower`). The result may lie
 * outside the range — callers clamp for display ("always"/"never" profitable).
 */
export function breakEvenCount(
  range: MarketRange,
  higher: bigint,
  lower: bigint,
  cost: bigint,
): number | null {
  if (higher === lower) return null;
  const span = Number(range.maxCount - range.minCount);
  // f* = (cost - lower) / (higher - lower), computed in floats for display.
  const f = Number(cost - lower) / Number(higher - lower);
  return Number(range.minCount) + span * f;
}

/** Applies a slippage tolerance (in bps) to a quoted amount, rounding down. */
export function minTokensOutForSlippage(quoted: bigint, slippageBps: number): bigint {
  const bps = BigInt(Math.round(slippageBps));
  if (bps < 0n || bps > BPS) throw new Error("slippage out of range");
  return (quoted * (BPS - bps)) / BPS;
}

/**
 * Average entry expressed as a count: the prediction your CST effectively
 * bought at, i.e. the count at which your bet exactly breaks even.
 */
export function entryCount(
  range: MarketRange,
  side: BetSide,
  cstIn: bigint,
  tokensOut: bigint,
): number | null {
  if (tokensOut === 0n) return null;
  return side === "higher"
    ? breakEvenCount(range, tokensOut, 0n, cstIn)
    : breakEvenCount(range, 0n, tokensOut, cstIn);
}

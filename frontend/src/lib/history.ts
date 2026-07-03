import type { BetSide, MarketRange, PoolState } from "./math";
import { applyBet, invertBet, predictedCountFloat } from "./math";

/** A Bet event, decoded. Ordering fields let us sort exactly as the chain did. */
export interface BetEvent {
  readonly blockNumber: bigint;
  readonly logIndex: number;
  readonly transactionHash: `0x${string}`;
  readonly user: `0x${string}`;
  readonly side: BetSide;
  readonly cstIn: bigint;
  readonly tokensOut: bigint;
  /** Unix seconds of the containing block, when known. */
  readonly timestamp: number | null;
}

export interface PricePoint {
  /** The market's predicted count after this event (fractional for smooth charts). */
  readonly predicted: number;
  readonly blockNumber: bigint;
  readonly logIndex: number;
  readonly timestamp: number | null;
}

/** Chain order: by block, then by log index within the block. */
export function sortEvents<T extends { blockNumber: bigint; logIndex: number }>(events: readonly T[]): T[] {
  return [...events].sort((a, b) => {
    if (a.blockNumber !== b.blockNumber) return a.blockNumber < b.blockNumber ? -1 : 1;
    return a.logIndex - b.logIndex;
  });
}

/**
 * Replays sorted Bet events forward from the market's opening pool (equal
 * reserves of `initialLiquidity`), producing the full prediction history.
 * The first point is the opening midpoint prediction.
 */
export function replayHistory(
  range: MarketRange,
  initialLiquidity: bigint,
  feeBps: bigint,
  events: readonly BetEvent[],
): { points: PricePoint[]; endPool: PoolState } {
  let pool: PoolState = { reserveHigher: initialLiquidity, reserveLower: initialLiquidity };
  const sorted = sortEvents(events);
  const points: PricePoint[] = [
    {
      predicted: predictedCountFloat(range, pool),
      blockNumber: sorted.length > 0 ? sorted[0].blockNumber : 0n,
      logIndex: -1,
      timestamp: null,
    },
  ];
  for (const ev of sorted) {
    pool = applyBet(ev.side, pool, ev.cstIn, feeBps).pool;
    points.push({
      predicted: predictedCountFloat(range, pool),
      blockNumber: ev.blockNumber,
      logIndex: ev.logIndex,
      timestamp: ev.timestamp,
    });
  }
  return { points, endPool: pool };
}

/**
 * Recovers the opening pool by unwinding sorted events backwards from the
 * current on-chain reserves. Sanity check for `replayHistory` (both must meet
 * in the middle) and a fallback when the initial liquidity isn't known.
 */
export function unwindToOpeningPool(
  current: PoolState,
  feeBps: bigint,
  events: readonly BetEvent[],
): PoolState {
  let pool = current;
  const sorted = sortEvents(events);
  for (let i = sorted.length - 1; i >= 0; i--) {
    const ev = sorted[i];
    pool = invertBet(ev.side, pool, ev.cstIn, ev.tokensOut, feeBps);
  }
  return pool;
}

/**
 * Derives the pool's opening liquidity L (the constructor seeds L/L):
 *
 * - With live reserves, unwind all recorded bets backwards — exact.
 * - After resolution the reserves are swept to zero, so instead solve L from
 *   the first recorded bet against a balanced pool:
 *   `tokensOut = net + L - ceil(L² / (L + net))` ⇒ `L ≈ d·net / (net − d)`
 *   with `d = tokensOut − net` (exact up to the contract's 1-wei rounding).
 * - With no reserves and no bets there is nothing to anchor on; returns null.
 */
export function deriveOpeningLiquidity(
  currentPool: PoolState | null,
  feeBps: bigint,
  events: readonly BetEvent[],
): bigint | null {
  if (currentPool && currentPool.reserveHigher + currentPool.reserveLower > 0n) {
    return unwindToOpeningPool(currentPool, feeBps, events).reserveHigher;
  }
  const sorted = sortEvents(events);
  if (sorted.length === 0) return null;
  const first = sorted[0];
  const fee = (first.cstIn * feeBps) / 10_000n;
  const net = first.cstIn - fee;
  const d = first.tokensOut - net;
  if (d <= 0n || net <= d) return null;
  return (d * net) / (net - d);
}

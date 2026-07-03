import type { Address } from "viem";
import type { BetEvent } from "./history";
import type { MarketRange, PoolState } from "./math";
import { claimValue, entryCount, positionValueAt, predictedCountFloat } from "./math";

/**
 * Lifecycle of a market:
 *  - `live`      — the round is running; betting, minting and redeeming are open.
 *  - `ended`     — the round finished but nobody called `resolve()` yet.
 *  - `resolved`  — payouts are fixed; claiming is open.
 */
export type MarketPhase = "live" | "ended" | "resolved";

/** Everything the UI needs about a market, fetched in one multicall. */
export interface MarketSnapshot {
  readonly address: Address;
  readonly round: bigint;
  readonly minCount: bigint;
  readonly maxCount: bigint;
  readonly feeBps: bigint;
  readonly reserveHigher: bigint;
  readonly reserveLower: bigint;
  readonly resolved: boolean;
  readonly finalGestureCount: bigint;
  readonly payoutPerHigher: bigint;
  readonly creator: Address;
  readonly cstAddress: Address;
  readonly gameAddress: Address;
  readonly feesAccrued: bigint;
  /** The game's current round counter (`> round` ⇒ this market's round is over). */
  readonly gameRoundNum: bigint;
  /** Live gesture count of the market's round so far (final once the round ends). */
  readonly liveGestureCount: bigint;
}

/** The connected user's stake in the market. */
export interface UserSnapshot {
  readonly address: Address;
  readonly higherBalance: bigint;
  readonly lowerBalance: bigint;
  readonly cstBalance: bigint;
  readonly cstAllowance: bigint;
}

export function marketPhase(snapshot: Pick<MarketSnapshot, "resolved" | "gameRoundNum" | "round">): MarketPhase {
  if (snapshot.resolved) return "resolved";
  if (snapshot.gameRoundNum > snapshot.round) return "ended";
  return "live";
}

export function marketRange(snapshot: Pick<MarketSnapshot, "minCount" | "maxCount">): MarketRange {
  return { minCount: snapshot.minCount, maxCount: snapshot.maxCount };
}

export function poolState(snapshot: Pick<MarketSnapshot, "reserveHigher" | "reserveLower">): PoolState {
  return { reserveHigher: snapshot.reserveHigher, reserveLower: snapshot.reserveLower };
}

/**
 * The number to show as "the market's prediction": live/ended markets read the
 * pool, resolved markets show the clamped final count.
 */
export function displayedPrediction(snapshot: MarketSnapshot): number {
  const range = marketRange(snapshot);
  if (marketPhase(snapshot) === "resolved") {
    const clamped =
      snapshot.finalGestureCount < snapshot.minCount
        ? snapshot.minCount
        : snapshot.finalGestureCount > snapshot.maxCount
          ? snapshot.maxCount
          : snapshot.finalGestureCount;
    return Number(clamped);
  }
  return predictedCountFloat(range, poolState(snapshot));
}

/**
 * What the user's tokens are worth in CST:
 *  - resolved: exact claim value at the fixed payout rate;
 *  - live/ended: value if the round ended at the current live gesture count.
 */
export function positionValue(market: MarketSnapshot, user: UserSnapshot): bigint {
  if (market.resolved) {
    return claimValue(user.higherBalance, user.lowerBalance, market.payoutPerHigher);
  }
  return positionValueAt(
    marketRange(market),
    user.higherBalance,
    user.lowerBalance,
    market.liveGestureCount,
  );
}

export function hasPosition(user: Pick<UserSnapshot, "higherBalance" | "lowerBalance">): boolean {
  return user.higherBalance > 0n || user.lowerBalance > 0n;
}

export interface UserEntries {
  /** Average entry count of the user's HIGHER bets (null if none). */
  readonly higher: number | null;
  /** Average entry count of the user's LOWER bets (null if none). */
  readonly lower: number | null;
  /** Total CST the user has wagered through bets. */
  readonly totalWagered: bigint;
}

/**
 * Aggregates a user's Bet events into average entry counts per side: the
 * gesture count at which the combined bet exactly breaks even. This is the
 * honest "your entry" number for positions built from multiple bets.
 */
export function userEntries(range: MarketRange, bets: readonly BetEvent[], user: Address): UserEntries {
  let higherIn = 0n;
  let higherOut = 0n;
  let lowerIn = 0n;
  let lowerOut = 0n;
  const target = user.toLowerCase();
  for (const bet of bets) {
    if (bet.user.toLowerCase() !== target) continue;
    if (bet.side === "higher") {
      higherIn += bet.cstIn;
      higherOut += bet.tokensOut;
    } else {
      lowerIn += bet.cstIn;
      lowerOut += bet.tokensOut;
    }
  }
  return {
    higher: higherOut > 0n ? entryCount(range, "higher", higherIn, higherOut) : null,
    lower: lowerOut > 0n ? entryCount(range, "lower", lowerIn, lowerOut) : null,
    totalWagered: higherIn + lowerIn,
  };
}

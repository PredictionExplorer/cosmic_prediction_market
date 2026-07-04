import type { Address } from "viem";
import type { PoolState, TierPool } from "./math";
import { aggregateProbabilityFloat, claimValue, positionValueAtProbability } from "./math";

/**
 * Lifecycle of one round's market:
 *  - `uninitialized` — nobody has added liquidity for this round yet.
 *  - `live`          — betting, liquidity and sets are open.
 *  - `decided`       — the gesture count crossed the threshold mid-round:
 *                      YES already won; betting/adds halted; resolve is open.
 *  - `ended`         — the round finished but nobody called `resolve` yet.
 *  - `resolved`      — the winner is fixed; claiming is open.
 */
export type RoundPhase = "uninitialized" | "live" | "decided" | "ended" | "resolved";

/** Everything the UI needs about one round of the series, in one multicall. */
export interface RoundSnapshot {
  readonly seriesAddress: Address;
  readonly roundId: bigint;
  readonly initialized: boolean;
  readonly resolved: boolean;
  readonly yesWon: boolean;
  /**
   * The previous round's final gesture count — the number to beat. For
   * uninitialized rounds this is read straight from the game (the value the
   * market would freeze at initialization).
   */
  readonly threshold: bigint;
  /** This round's gesture count so far (final once the round ends). */
  readonly currentCount: bigint;
  /** The game's current round counter. */
  readonly gameRoundNum: bigint;
  /** One pool per fee tier, ascending by fee. */
  readonly pools: readonly TierPool[];
  readonly cstAddress: Address;
  readonly gameAddress: Address;
}

/** One LP position of the connected user. */
export interface LpPosition {
  readonly feeBps: number;
  readonly shares: bigint;
  readonly pendingFees: bigint;
}

/** The connected user's stake in one round. */
export interface UserSnapshot {
  readonly address: Address;
  readonly yesBalance: bigint;
  readonly noBalance: bigint;
  readonly cstBalance: bigint;
  readonly cstAllowance: bigint;
  readonly lpPositions: readonly LpPosition[];
}

export function roundPhase(
  s: Pick<RoundSnapshot, "initialized" | "resolved" | "roundId" | "gameRoundNum" | "currentCount" | "threshold">,
): RoundPhase {
  if (s.resolved) return "resolved";
  if (!s.initialized) return "uninitialized";
  if (s.gameRoundNum > s.roundId) return "ended";
  if (s.currentCount > s.threshold) return "decided";
  return "live";
}

/** Whether betting is currently possible. */
export function isTradable(s: RoundSnapshot): boolean {
  return roundPhase(s) === "live";
}

/**
 * Whether `addLiquidity` would succeed: the round is live (or still
 * uninitialized but open-able — current, with a previous round, and with the
 * outcome still uncertain).
 */
export function canAddLiquidity(s: RoundSnapshot): boolean {
  const phase = roundPhase(s);
  if (phase === "live") return true;
  return (
    phase === "uninitialized" &&
    s.roundId >= 1n &&
    s.gameRoundNum === s.roundId &&
    s.currentCount <= s.threshold
  );
}

/** Whether `resolve()` would succeed right now. */
export function isResolvable(s: RoundSnapshot): boolean {
  const phase = roundPhase(s);
  return phase === "ended" || phase === "decided";
}

/** Total outcome tokens across all tier pools (a liquidity gauge). */
export function totalLiquidity(pools: readonly TierPool[]): bigint {
  return pools.reduce((acc, { pool }) => acc + pool.reserveYes + pool.reserveNo, 0n);
}

/** Total unclaimed LP fee escrow across pools. */
export function totalFeeReserve(pools: readonly TierPool[]): bigint {
  return pools.reduce((acc, { pool }) => acc + pool.feeReserve, 0n);
}

/**
 * The headline probability the UI shows for YES ("this round beats the last
 * one"), in [0,1]:
 *  - resolved: exactly 0 or 1;
 *  - decided: 1 (the count already crossed);
 *  - otherwise: the liquidity-weighted pool-implied probability, or null when
 *    no pool has liquidity yet.
 */
export function displayedProbability(s: RoundSnapshot): number | null {
  const phase = roundPhase(s);
  if (phase === "resolved") return s.yesWon ? 1 : 0;
  if (phase === "decided") return 1;
  return aggregateProbabilityFloat(s.pools);
}

/**
 * What the user's outcome tokens are worth in CST:
 *  - resolved: the exact claim value;
 *  - decided: YES is certain (its tokens are worth 1, NO worth 0);
 *  - live/ended: marked at the displayed probability (float, display-only).
 */
export function positionValueFloat(s: RoundSnapshot, user: Pick<UserSnapshot, "yesBalance" | "noBalance">): number {
  const phase = roundPhase(s);
  if (phase === "resolved") return Number(claimValue(user.yesBalance, user.noBalance, s.yesWon)) / 1e18;
  if (phase === "decided") return Number(user.yesBalance) / 1e18;
  const p = displayedProbability(s);
  return positionValueAtProbability(user.yesBalance, user.noBalance, p ?? 0.5);
}

export function hasPosition(user: Pick<UserSnapshot, "yesBalance" | "noBalance">): boolean {
  return user.yesBalance > 0n || user.noBalance > 0n;
}

export function hasLpPosition(user: Pick<UserSnapshot, "lpPositions">): boolean {
  return user.lpPositions.some((p) => p.shares > 0n || p.pendingFees > 0n);
}

/** The pool for a tier, if it exists in the snapshot. */
export function poolForTier(pools: readonly TierPool[], feeBps: number): PoolState | null {
  return pools.find((p) => p.feeBps === feeBps)?.pool ?? null;
}

/** How far the current count is toward the threshold, in [0,1] (can exceed). */
export function thresholdProgress(s: Pick<RoundSnapshot, "currentCount" | "threshold">): number {
  if (s.threshold === 0n) return s.currentCount > 0n ? 1 : 0;
  return Number(s.currentCount) / Number(s.threshold);
}

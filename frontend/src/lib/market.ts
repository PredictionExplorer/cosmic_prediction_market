import type { Address } from "viem";
import type { PoolState } from "./math";
import { claimValue, currentFeeBps, poolIsTradable, positionValueAtProbability, probabilityFloat } from "./math";

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
  /** The round's single pool. */
  readonly pool: PoolState;
  readonly cstAddress: Address;
  readonly gameAddress: Address;
}

/** The connected user's stake in one round. */
export interface UserSnapshot {
  readonly address: Address;
  readonly yesBalance: bigint;
  readonly noBalance: bigint;
  readonly cstBalance: bigint;
  readonly cstAllowance: bigint;
  /** LP position: shares, claimable fees, and the user's fee vote. */
  readonly lpShares: bigint;
  readonly lpPendingFees: bigint;
  readonly lpDeclaredFeeBps: number;
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
  return roundPhase(s) === "live" && poolIsTradable(s.pool);
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
    phase === "uninitialized" && s.roundId >= 1n && s.gameRoundNum === s.roundId && s.currentCount <= s.threshold
  );
}

/** Whether `resolve()` would succeed right now. */
export function isResolvable(s: RoundSnapshot): boolean {
  const phase = roundPhase(s);
  return phase === "ended" || phase === "decided";
}

/** Total outcome tokens in the pool (a liquidity gauge). */
export function totalLiquidity(pool: PoolState): bigint {
  return pool.reserveYes + pool.reserveNo;
}

/** The pool's live weighted-average fee, in bps (number, for display). */
export function poolFeeBps(pool: PoolState): number {
  return Number(currentFeeBps(pool));
}

/**
 * The headline probability the UI shows for YES ("this round beats the last
 * one"), in [0,1]:
 *  - resolved: exactly 0 or 1;
 *  - decided: 1 (the count already crossed);
 *  - otherwise: the pool-implied probability, or null when unfunded.
 */
export function displayedProbability(s: RoundSnapshot): number | null {
  const phase = roundPhase(s);
  if (phase === "resolved") return s.yesWon ? 1 : 0;
  if (phase === "decided") return 1;
  return probabilityFloat(s.pool);
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

export function hasLpPosition(user: Pick<UserSnapshot, "lpShares" | "lpPendingFees">): boolean {
  return user.lpShares > 0n || user.lpPendingFees > 0n;
}

/** How far the current count is toward the threshold, in [0,1] (can exceed). */
export function thresholdProgress(s: Pick<RoundSnapshot, "currentCount" | "threshold">): number {
  if (s.threshold === 0n) return s.currentCount > 0n ? 1 : 0;
  return Number(s.currentCount) / Number(s.threshold);
}

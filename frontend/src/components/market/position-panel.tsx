"use client";

import { Gift, RefreshCcw } from "lucide-react";
import { useMemo, useState } from "react";
import { formatCount, formatCst } from "@/lib/format";
import type { MarketSnapshot, UserSnapshot } from "@/lib/market";
import { hasPosition, marketPhase, marketRange, positionValue } from "@/lib/market";
import { claimValue, payoutPerHigherFor } from "@/lib/math";
import { AnimatedNumber } from "@/components/ui/animated-number";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";

export interface PositionPanelProps {
  snapshot: MarketSnapshot;
  user: UserSnapshot;
  /**
   * The final count at which the position pays back exactly what the user
   * wagered (computed from their bet history). Null when unknown or balanced.
   */
  breakEven: number | null;
  pendingAction: "redeem" | "claim" | null;
  onRedeemSets: (amount: bigint) => Promise<boolean>;
  onClaim: () => Promise<boolean>;
}

/**
 * The connected user's stake: token balances, live value, break-even, an
 * interactive "what if the round ends at N" explorer, redeeming complete
 * sets, and claiming after resolution.
 */
export function PositionPanel({
  snapshot,
  user,
  breakEven,
  pendingAction,
  onRedeemSets,
  onClaim,
}: PositionPanelProps) {
  const phase = marketPhase(snapshot);
  const range = marketRange(snapshot);
  const value = positionValue(snapshot, user);
  const sets = user.higherBalance < user.lowerBalance ? user.higherBalance : user.lowerBalance;

  const [whatIf, setWhatIf] = useState<number | null>(null);
  const whatIfCount = whatIf ?? Number(snapshot.liveGestureCount);
  const whatIfValue = useMemo(
    () =>
      claimValue(
        user.higherBalance,
        user.lowerBalance,
        payoutPerHigherFor(range, BigInt(Math.round(whatIfCount))),
      ),
    [user.higherBalance, user.lowerBalance, range, whatIfCount],
  );

  if (!hasPosition(user)) return null;

  const min = Number(snapshot.minCount);
  const max = Number(snapshot.maxCount);

  return (
    <Card accent="nova" className="p-5" data-testid="position-panel">
      <div className="flex items-center justify-between">
        <h2 className="font-display text-lg font-semibold">Your position</h2>
        {phase === "resolved" ? (
          <span className="text-xs text-ink-faint">settled at {formatCount(snapshot.finalGestureCount)} gestures</span>
        ) : (
          <span className="text-xs text-ink-faint">marked at {formatCount(snapshot.liveGestureCount)} gestures so far</span>
        )}
      </div>

      <div className="mt-4 grid grid-cols-3 gap-3">
        <div className="rounded-xl border border-higher/25 bg-higher/8 p-3">
          <p className="text-[10px] font-semibold uppercase tracking-wider text-higher">Higher</p>
          <p className="mt-1 font-mono text-lg font-semibold" data-testid="higher-balance">
            {formatCst(user.higherBalance)}
          </p>
        </div>
        <div className="rounded-xl border border-lower/25 bg-lower/8 p-3">
          <p className="text-[10px] font-semibold uppercase tracking-wider text-lower">Lower</p>
          <p className="mt-1 font-mono text-lg font-semibold" data-testid="lower-balance">
            {formatCst(user.lowerBalance)}
          </p>
        </div>
        <div className="rounded-xl border border-nova/25 bg-nova/8 p-3">
          <p className="text-[10px] font-semibold uppercase tracking-wider text-nova-bright">
            {phase === "resolved" ? "Claimable" : "Value now"}
          </p>
          <p className="mt-1 font-mono text-lg font-semibold" data-testid="position-value">
            <AnimatedNumber
              value={Number(value) / 1e18}
              format={(v) => v.toLocaleString("en-US", { maximumFractionDigits: 2 })}
            />{" "}
            <span className="text-xs text-ink-dim">CST</span>
          </p>
        </div>
      </div>

      {breakEven !== null && phase !== "resolved" && (
        <p className="mt-3 text-center text-xs text-ink-faint" data-testid="break-even">
          You come out ahead if the final count lands{" "}
          {user.higherBalance > user.lowerBalance ? "above" : "below"} ~
          <span className="font-mono text-ink">{formatCount(Math.min(Math.max(breakEven, min), max))}</span>{" "}
          gestures
        </p>
      )}

      {/* What-if explorer */}
      {phase !== "resolved" && (
        <div className="mt-4 rounded-xl border border-line bg-surface-2/40 p-4" data-testid="what-if">
          <div className="flex items-baseline justify-between text-xs">
            <span className="text-ink-faint">If the round ends at</span>
            <span className="font-mono font-semibold text-ink" data-testid="what-if-count">
              {formatCount(whatIfCount)} gestures
            </span>
          </div>
          <input
            type="range"
            className="cosmic-range mt-3"
            min={min}
            max={max}
            step={Math.max(1, Math.round((max - min) / 500))}
            value={whatIfCount}
            onChange={(e) => setWhatIf(Number(e.target.value))}
            aria-label="Explore payout at a hypothetical final gesture count"
            data-testid="what-if-slider"
          />
          <div className="mt-2 flex items-baseline justify-between text-xs">
            <span className="text-ink-faint">your tokens pay</span>
            <span className="font-mono font-semibold text-nova-bright" data-testid="what-if-value">
              {formatCst(whatIfValue)} CST
            </span>
          </div>
        </div>
      )}

      <div className="mt-4 flex flex-col gap-2">
        {phase === "resolved" && (
          <Button
            variant="nova"
            size="lg"
            className="w-full"
            loading={pendingAction === "claim"}
            disabled={value === 0n && !hasPosition(user)}
            onClick={() => void onClaim()}
            data-testid="claim-button"
          >
            <Gift className="size-4" aria-hidden />
            Claim {formatCst(value)} CST
          </Button>
        )}

        {phase === "live" && sets > 0n && (
          <div className="flex items-center justify-between gap-3 rounded-xl border border-line bg-surface-2/40 px-4 py-3">
            <p className="text-xs text-ink-dim">
              You hold <span className="font-mono text-ink">{formatCst(sets)}</span> complete sets —
              redeemable 1:1 for CST
            </p>
            <Button
              variant="outline"
              size="sm"
              loading={pendingAction === "redeem"}
              onClick={() => void onRedeemSets(sets)}
              data-testid="redeem-button"
            >
              <RefreshCcw className="size-3.5" aria-hidden />
              Redeem
            </Button>
          </div>
        )}
      </div>
    </Card>
  );
}

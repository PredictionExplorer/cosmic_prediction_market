"use client";

import { Gift, RefreshCcw } from "lucide-react";
import { formatCst } from "@/lib/format";
import type { RoundSnapshot, UserSnapshot } from "@/lib/market";
import { displayedProbability, hasPosition, positionValueFloat, roundPhase } from "@/lib/market";
import { claimValue } from "@/lib/math";
import { AnimatedNumber } from "@/components/ui/animated-number";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";

export interface PositionPanelProps {
  snapshot: RoundSnapshot;
  user: UserSnapshot;
  pendingAction: "redeem" | "claim" | null;
  onRedeemSets: (amount: bigint) => Promise<boolean>;
  onClaim: () => Promise<boolean>;
}

/**
 * The connected user's outcome tokens: YES/NO balances, their mark-to-market
 * value, redeeming complete sets, and claiming after resolution.
 */
export function PositionPanel({ snapshot, user, pendingAction, onRedeemSets, onClaim }: PositionPanelProps) {
  const phase = roundPhase(snapshot);
  const value = positionValueFloat(snapshot, user);
  const sets = user.yesBalance < user.noBalance ? user.yesBalance : user.noBalance;
  const probability = displayedProbability(snapshot);
  const claimable = phase === "resolved" ? claimValue(user.yesBalance, user.noBalance, snapshot.yesWon) : 0n;

  if (!hasPosition(user)) return null;

  return (
    <Card accent="nova" className="p-5" data-testid="position-panel">
      <div className="flex items-center justify-between">
        <h2 className="font-display text-lg font-semibold">Your position</h2>
        <span className="text-xs text-ink-faint">
          {phase === "resolved"
            ? `settled — ${snapshot.yesWon ? "YES" : "NO"} won`
            : probability === null
              ? "no market price yet"
              : `marked at ${(probability * 100).toLocaleString("en-US", { maximumFractionDigits: 1 })}% YES`}
        </span>
      </div>

      <div className="mt-4 grid grid-cols-3 gap-3">
        <div className="rounded-xl border border-higher/25 bg-higher/8 p-3">
          <p className="text-[10px] font-semibold uppercase tracking-wider text-higher">Yes</p>
          <p className="mt-1 font-mono text-lg font-semibold" data-testid="yes-balance">
            {formatCst(user.yesBalance)}
          </p>
        </div>
        <div className="rounded-xl border border-lower/25 bg-lower/8 p-3">
          <p className="text-[10px] font-semibold uppercase tracking-wider text-lower">No</p>
          <p className="mt-1 font-mono text-lg font-semibold" data-testid="no-balance">
            {formatCst(user.noBalance)}
          </p>
        </div>
        <div className="rounded-xl border border-nova/25 bg-nova/8 p-3">
          <p className="text-[10px] font-semibold uppercase tracking-wider text-nova-bright">
            {phase === "resolved" ? "Claimable" : "Value now"}
          </p>
          <p className="mt-1 font-mono text-lg font-semibold" data-testid="position-value">
            <AnimatedNumber value={value} format={(v) => v.toLocaleString("en-US", { maximumFractionDigits: 2 })} />{" "}
            <span className="text-xs text-ink-dim">CST</span>
          </p>
        </div>
      </div>

      {phase === "decided" && (
        <p className="mt-3 rounded-xl border border-ended/30 bg-ended/8 p-3 text-center text-xs text-ended" data-testid="decided-note">
          The count crossed the threshold — YES has already won. Resolve the round to unlock claiming.
        </p>
      )}

      <div className="mt-4 flex flex-col gap-2">
        {phase === "resolved" && (
          <Button
            variant="nova"
            size="lg"
            className="w-full"
            loading={pendingAction === "claim"}
            onClick={() => void onClaim()}
            data-testid="claim-button"
          >
            <Gift className="size-4" aria-hidden />
            Claim {formatCst(claimable)} CST
          </Button>
        )}

        {phase !== "resolved" && sets > 0n && (
          <div className="flex items-center justify-between gap-3 rounded-xl border border-line bg-surface-2/40 px-4 py-3">
            <p className="text-xs text-ink-dim">
              You hold <span className="font-mono text-ink">{formatCst(sets)}</span> complete sets — redeemable 1:1
              for CST
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

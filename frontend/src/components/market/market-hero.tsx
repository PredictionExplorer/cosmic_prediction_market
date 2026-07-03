"use client";

import type { MarketSnapshot } from "@/lib/market";
import { displayedPrediction, marketPhase } from "@/lib/market";
import type { PricePoint } from "@/lib/history";
import { formatCount, formatCountPrecise } from "@/lib/format";
import { AnimatedNumber } from "@/components/ui/animated-number";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { PredictionChart } from "./prediction-chart";
import { PredictionGauge } from "./prediction-gauge";

interface MarketHeroProps {
  snapshot: MarketSnapshot;
  history: readonly PricePoint[];
  /** Break-even of the connected user's position, for the gauge marker. */
  breakEven?: number | null;
}

const PHASE_BADGE = {
  live: { tone: "higher" as const, label: "Live", pulse: true },
  ended: { tone: "ended" as const, label: "Round ended — awaiting resolution", pulse: true },
  resolved: { tone: "nova" as const, label: "Resolved", pulse: false },
};

/** The market's centerpiece: what the crowd currently predicts. */
export function MarketHero({ snapshot, history, breakEven }: MarketHeroProps) {
  const phase = marketPhase(snapshot);
  const prediction = displayedPrediction(snapshot);
  const badge = PHASE_BADGE[phase];

  return (
    <Card accent="nova" className="p-6 sm:p-8" data-testid="market-hero">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <Badge tone={badge.tone} pulse={badge.pulse} data-testid="phase-badge">
            {badge.label}
          </Badge>
          <Badge tone="muted">Round {snapshot.round.toString()}</Badge>
        </div>
        <p className="text-xs text-ink-faint">
          Gestures so far:{" "}
          <span className="font-mono font-semibold text-ink" data-testid="live-count">
            {formatCount(snapshot.liveGestureCount)}
          </span>
        </p>
      </div>

      <div className="mt-6 flex flex-col items-center text-center">
        <p className="text-[11px] font-semibold uppercase tracking-[0.28em] text-ink-dim">
          {phase === "resolved" ? "Final gesture count" : "The market predicts"}
        </p>
        <div className="mt-1 font-display text-6xl font-bold tabular-nums sm:text-7xl">
          {phase === "resolved" ? (
            <span className="text-ended" data-testid="final-count">
              {formatCount(snapshot.finalGestureCount)}
            </span>
          ) : (
            <AnimatedNumber
              value={prediction}
              format={formatCountPrecise}
              className="text-glow-nova text-ink"
            />
          )}
        </div>
        <p className="mt-1 text-sm text-ink-dim">
          {phase === "resolved" ? (
            <>
              gestures — HIGHER paid{" "}
              <span className="font-mono text-higher">
                {(Number(snapshot.payoutPerHigher) / 1e18).toLocaleString("en-US", {
                  maximumFractionDigits: 3,
                })}
              </span>{" "}
              CST, LOWER paid{" "}
              <span className="font-mono text-lower">
                {(1 - Number(snapshot.payoutPerHigher) / 1e18).toLocaleString("en-US", {
                  maximumFractionDigits: 3,
                })}
              </span>{" "}
              CST per token
            </>
          ) : (
            <>gestures by the end of this round</>
          )}
        </p>
      </div>

      <div className="mt-8">
        <PredictionGauge
          min={Number(snapshot.minCount)}
          max={Number(snapshot.maxCount)}
          prediction={prediction}
          liveCount={Number(snapshot.liveGestureCount)}
          breakEven={breakEven}
          resolved={phase === "resolved"}
        />
      </div>

      <div className="mt-6">
        <PredictionChart
          points={history}
          min={Number(snapshot.minCount)}
          max={Number(snapshot.maxCount)}
        />
      </div>
    </Card>
  );
}

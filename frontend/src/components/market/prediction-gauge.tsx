"use client";

import { motion, useReducedMotion } from "motion/react";
import { formatCount } from "@/lib/format";

export interface GaugeProps {
  min: number;
  max: number;
  /** The market's current prediction (pool-implied or final). */
  prediction: number;
  /** Gestures actually placed so far this round (live floor under the outcome). */
  liveCount?: number | null;
  /** The user's break-even count, when they hold a directional position. */
  breakEven?: number | null;
  resolved?: boolean;
}

export function gaugeFraction(min: number, max: number, value: number): number {
  if (max <= min) return 0;
  return Math.min(1, Math.max(0, (value - min) / (max - min)));
}

/**
 * The market range as a horizontal spectrum from LOWER (rose) to HIGHER
 * (green), with the live prediction as a glowing marker, the actual gesture
 * count so far as a tick, and the user's break-even when present.
 */
export function PredictionGauge({ min, max, prediction, liveCount, breakEven, resolved = false }: GaugeProps) {
  const reduced = useReducedMotion();
  const predictionPct = gaugeFraction(min, max, prediction) * 100;
  const livePct = liveCount != null ? gaugeFraction(min, max, liveCount) * 100 : null;
  const breakEvenPct = breakEven != null ? gaugeFraction(min, max, breakEven) * 100 : null;

  return (
    <div data-testid="prediction-gauge" className="w-full select-none">
      <div className="relative h-10">
        {/* Track */}
        <div className="absolute inset-x-0 top-1/2 h-2.5 -translate-y-1/2 rounded-full bg-gradient-to-r from-lower/70 via-nova/50 to-higher/70 opacity-90" />
        <div className="absolute inset-x-0 top-1/2 h-2.5 -translate-y-1/2 rounded-full bg-space/45" style={{ left: "0%", right: `${100 - predictionPct}%` }} />

        {/* Live gesture count tick */}
        {livePct != null && (
          <div
            data-testid="gauge-live-tick"
            className="absolute top-1/2 h-6 w-0.5 -translate-x-1/2 -translate-y-1/2 rounded bg-ink/80"
            style={{ left: `${livePct}%` }}
            title={`Gestures so far: ${formatCount(liveCount ?? 0)}`}
          />
        )}

        {/* Break-even marker */}
        {breakEvenPct != null && (
          <div
            data-testid="gauge-breakeven"
            className="absolute top-1/2 size-2.5 -translate-x-1/2 -translate-y-1/2 rotate-45 border border-space bg-ended"
            style={{ left: `${breakEvenPct}%` }}
            title={`Your break-even: ${formatCount(breakEven ?? 0)}`}
          />
        )}

        {/* Prediction marker */}
        <motion.div
          data-testid="gauge-marker"
          className="absolute top-1/2 z-10 -translate-x-1/2 -translate-y-1/2"
          animate={{ left: `${predictionPct}%` }}
          initial={false}
          transition={reduced ? { duration: 0 } : { type: "spring", stiffness: 120, damping: 20 }}
          style={reduced ? { left: `${predictionPct}%` } : undefined}
        >
          <div
            className={[
              "size-5 rounded-full border-[3px] border-space",
              resolved ? "bg-ended shadow-[0_0_18px_rgba(255,195,85,0.9)]" : "bg-ink shadow-[0_0_18px_rgba(240,237,250,0.75)]",
            ].join(" ")}
          />
        </motion.div>
      </div>

      <div className="mt-1 flex items-baseline justify-between font-mono text-xs text-ink-faint">
        <span data-testid="gauge-min">{formatCount(min)}</span>
        <span className="text-[10px] uppercase tracking-widest text-ink-faint/80">gesture count range</span>
        <span data-testid="gauge-max">{formatCount(max)}</span>
      </div>
    </div>
  );
}

"use client";

import type { ProbabilityPoint } from "@/lib/history";
import type { RoundSnapshot } from "@/lib/market";
import { displayedProbability, roundPhase } from "@/lib/market";
import { formatCount } from "@/lib/format";
import { AnimatedNumber } from "@/components/ui/animated-number";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { ProbabilityChart } from "./probability-chart";
import { ThresholdRace } from "./threshold-race";

interface MarketHeroProps {
  snapshot: RoundSnapshot;
  history: readonly ProbabilityPoint[];
}

const PHASE_BADGE = {
  uninitialized: { tone: "muted" as const, label: "Awaiting first liquidity", pulse: false },
  future: { tone: "nova" as const, label: "Future round — open for early positions", pulse: false },
  live: { tone: "higher" as const, label: "Live", pulse: true },
  decided: { tone: "ended" as const, label: "Threshold crossed — YES won, awaiting resolution", pulse: true },
  ended: { tone: "ended" as const, label: "Round ended — awaiting resolution", pulse: true },
  resolved: { tone: "nova" as const, label: "Resolved", pulse: false },
};

/** The threshold line: locked value, forming value, or not-yet-knowable. */
function ThresholdCopy({ snapshot }: { snapshot: RoundSnapshot }) {
  if (snapshot.thresholdKnown) {
    return (
      <p className="text-xs text-ink-faint">
        Beat last round&apos;s{" "}
        <span className="font-mono font-semibold text-ended" data-testid="hero-threshold">
          {formatCount(snapshot.threshold)}
        </span>{" "}
        gestures
      </p>
    );
  }
  const prevRound = snapshot.roundId - 1n;
  if (snapshot.roundId === snapshot.gameRoundNum + 1n) {
    return (
      <p className="text-xs text-ink-faint" data-testid="hero-threshold-forming">
        Threshold forming:{" "}
        <span className="font-mono font-semibold text-ended">{formatCount(snapshot.prevRoundCount)}</span> gestures in
        round {prevRound.toString()} so far, still climbing
      </p>
    );
  }
  return (
    <p className="text-xs text-ink-faint" data-testid="hero-threshold-unknown">
      Threshold locks when round {prevRound.toString()} ends
    </p>
  );
}

/** The market's centerpiece: will this round out-gesture the last one? */
export function MarketHero({ snapshot, history }: MarketHeroProps) {
  const phase = roundPhase(snapshot);
  const probability = displayedProbability(snapshot);
  const badge = PHASE_BADGE[phase];

  return (
    <Card accent="nova" className="p-6 sm:p-8" data-testid="market-hero">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <Badge tone={badge.tone} pulse={badge.pulse} data-testid="phase-badge">
            {badge.label}
          </Badge>
          <Badge tone="muted">Round {snapshot.roundId.toString()}</Badge>
        </div>
        <ThresholdCopy snapshot={snapshot} />
      </div>

      <div className="mt-6 flex flex-col items-center text-center">
        <p className="text-[11px] font-semibold uppercase tracking-[0.28em] text-ink-dim">
          {phase === "resolved"
            ? snapshot.yesWon
              ? "Resolved: YES — more gestures than last round"
              : "Resolved: NO — didn't beat last round"
            : "Chance this round beats the last one"}
        </p>
        <div className="mt-1 font-display text-6xl font-bold tabular-nums sm:text-7xl">
          {probability === null ? (
            <span className="text-ink-faint" data-testid="hero-no-liquidity">
              —
            </span>
          ) : (
            <span className={phase === "resolved" ? "text-ended" : "text-glow-nova text-ink"} data-testid="hero-probability">
              <AnimatedNumber
                value={probability * 100}
                format={(v) => `${v.toLocaleString("en-US", { minimumFractionDigits: 1, maximumFractionDigits: 1 })}%`}
              />
            </span>
          )}
        </div>
        <p className="mt-1 text-sm text-ink-dim">
          {phase === "resolved" ? (
            <>
              final count{" "}
              <span className="font-mono font-semibold text-ink" data-testid="hero-final-count">
                {formatCount(snapshot.currentCount)}
              </span>{" "}
              vs threshold {formatCount(snapshot.threshold)} — winning tokens pay 1 CST each
            </>
          ) : probability === null ? (
            <>no liquidity yet — the first LP opens the market at their chosen odds</>
          ) : (
            <>implied by the pools, weighted by liquidity</>
          )}
        </p>
      </div>

      <div className="mt-8">
        <ThresholdRace
          currentCount={Number(snapshot.currentCount)}
          threshold={Number(snapshot.threshold)}
          thresholdKnown={snapshot.thresholdKnown}
          prevRoundId={snapshot.roundId === 0n ? null : snapshot.roundId - 1n}
          resolved={phase === "resolved"}
          yesWon={snapshot.yesWon}
        />
      </div>

      <div className="mt-6">
        <ProbabilityChart points={history} />
      </div>
    </Card>
  );
}

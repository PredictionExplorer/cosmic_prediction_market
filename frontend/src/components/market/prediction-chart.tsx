"use client";

import { useId, useMemo } from "react";
import type { PricePoint } from "@/lib/history";
import { formatCountPrecise } from "@/lib/format";

interface PredictionChartProps {
  points: readonly PricePoint[];
  min: number;
  max: number;
  height?: number;
  className?: string;
}

export interface ChartGeometry {
  linePath: string;
  areaPath: string;
  lastX: number;
  lastY: number;
}

/**
 * Maps prediction points onto SVG coordinates (x = trade sequence, y = count).
 * Pure and exported for direct testing.
 */
export function buildChartGeometry(
  points: readonly PricePoint[],
  min: number,
  max: number,
  width: number,
  height: number,
  pad = 6,
): ChartGeometry | null {
  if (points.length === 0 || max <= min) return null;
  const usableW = width - pad * 2;
  const usableH = height - pad * 2;
  const n = points.length;
  const x = (i: number) => pad + (n === 1 ? usableW / 2 : (i / (n - 1)) * usableW);
  const y = (v: number) => {
    const f = Math.min(1, Math.max(0, (v - min) / (max - min)));
    return pad + (1 - f) * usableH;
  };
  const coords = points.map((p, i) => [x(i), y(p.predicted)] as const);
  const linePath = coords.map(([cx, cy], i) => `${i === 0 ? "M" : "L"}${cx.toFixed(2)},${cy.toFixed(2)}`).join(" ");
  const [lastX, lastY] = coords[coords.length - 1];
  const areaPath = `${linePath} L${lastX.toFixed(2)},${(height - pad).toFixed(2)} L${coords[0][0].toFixed(2)},${(height - pad).toFixed(2)} Z`;
  return { linePath, areaPath, lastX, lastY };
}

/**
 * Prediction history as a glowing area chart. X is the trade sequence (each
 * bet is one step), which is the natural clock of an AMM market.
 */
export function PredictionChart({ points, min, max, height = 160, className = "" }: PredictionChartProps) {
  const gradientId = useId();
  const width = 640;
  const geometry = useMemo(() => buildChartGeometry(points, min, max, width, height), [points, min, max, height]);

  if (!geometry || points.length < 2) {
    return (
      <div
        data-testid="chart-empty"
        className={`flex items-center justify-center rounded-xl border border-dashed border-line text-sm text-ink-faint ${className}`}
        style={{ height }}
      >
        The prediction line will appear after the first bet.
      </div>
    );
  }

  const first = points[0].predicted;
  const last = points[points.length - 1].predicted;
  const rising = last >= first;
  const stroke = rising ? "var(--color-higher)" : "var(--color-lower)";

  return (
    <figure className={className} data-testid="prediction-chart">
      <svg
        viewBox={`0 0 ${width} ${height}`}
        className="w-full"
        style={{ height }}
        preserveAspectRatio="none"
        role="img"
        aria-label={`Prediction history from ${formatCountPrecise(first)} to ${formatCountPrecise(last)} gestures`}
      >
        <defs>
          <linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={stroke} stopOpacity="0.28" />
            <stop offset="100%" stopColor={stroke} stopOpacity="0" />
          </linearGradient>
        </defs>
        {/* Midline reference */}
        <line
          x1="6"
          x2={width - 6}
          y1={height / 2}
          y2={height / 2}
          stroke="var(--color-line)"
          strokeDasharray="4 6"
          strokeWidth="1"
        />
        <path d={geometry.areaPath} fill={`url(#${gradientId})`} />
        <path d={geometry.linePath} fill="none" stroke={stroke} strokeWidth="2.25" strokeLinejoin="round" strokeLinecap="round" />
        <circle cx={geometry.lastX} cy={geometry.lastY} r="4" fill={stroke}>
          <animate attributeName="opacity" values="1;0.4;1" dur="2s" repeatCount="indefinite" />
        </circle>
      </svg>
    </figure>
  );
}

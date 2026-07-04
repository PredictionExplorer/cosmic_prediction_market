import { render, screen } from "@testing-library/react";
import fc from "fast-check";
import { describe, expect, it } from "vitest";
import type { ProbabilityPoint } from "@/lib/history";
import { buildChartGeometry, ProbabilityChart } from "./probability-chart";

function point(probability: number, i: number): ProbabilityPoint {
  return { probability, blockNumber: BigInt(i), logIndex: i, timestamp: null };
}

describe("buildChartGeometry", () => {
  it("returns null for empty input", () => {
    expect(buildChartGeometry([], 640, 160)).toBeNull();
  });

  it("property: all y coordinates stay inside the padded viewbox", () => {
    fc.assert(
      fc.property(
        fc.array(fc.double({ min: 0, max: 1, noNaN: true }), { minLength: 1, maxLength: 60 }),
        (probs) => {
          const geometry = buildChartGeometry(
            probs.map((p, i) => point(p, i)),
            640,
            160,
          );
          expect(geometry).not.toBeNull();
          const ys = geometry!.linePath.match(/,(\d+(?:\.\d+)?)/g)!.map((m) => Number(m.slice(1)));
          for (const y of ys) {
            expect(y).toBeGreaterThanOrEqual(6);
            expect(y).toBeLessThanOrEqual(154);
          }
        },
      ),
    );
  });

  it("maps 0% to the bottom and 100% to the top", () => {
    const geometry = buildChartGeometry([point(0, 0), point(1, 1)], 640, 160)!;
    // First point at y = height - pad, last at y = pad.
    expect(geometry.linePath.startsWith("M6.00,154.00")).toBe(true);
    expect(geometry.lastY).toBe(6);
  });
});

describe("ProbabilityChart", () => {
  it("renders an empty state below two points", () => {
    render(<ProbabilityChart points={[point(0.5, 0)]} />);
    expect(screen.getByTestId("chart-empty")).toBeInTheDocument();
  });

  it("renders the chart with the 0–100% scale caption", () => {
    render(<ProbabilityChart points={[point(0.4, 0), point(0.6, 1), point(0.7, 2)]} />);
    expect(screen.getByTestId("probability-chart")).toBeInTheDocument();
    expect(screen.getByText("P(YES) over trades")).toBeInTheDocument();
  });
});

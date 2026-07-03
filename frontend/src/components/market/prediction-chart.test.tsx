import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { PricePoint } from "@/lib/history";
import { buildChartGeometry, PredictionChart } from "./prediction-chart";

function point(predicted: number, i: number): PricePoint {
  return { predicted, blockNumber: BigInt(i), logIndex: i, timestamp: null };
}

describe("buildChartGeometry", () => {
  it("returns null for empty input or degenerate range", () => {
    expect(buildChartGeometry([], 0, 100, 640, 160)).toBeNull();
    expect(buildChartGeometry([point(50, 0)], 100, 100, 640, 160)).toBeNull();
  });

  it("maps values linearly with padding and clamps outliers", () => {
    const geometry = buildChartGeometry([point(0, 0), point(100, 1)], 0, 100, 640, 160, 6);
    expect(geometry).not.toBeNull();
    // First point at min → bottom edge (height - pad). Last at max → top (pad).
    expect(geometry!.linePath.startsWith("M6.00,154.00")).toBe(true);
    expect(geometry!.lastY).toBeCloseTo(6);
    expect(geometry!.lastX).toBeCloseTo(634);
  });

  it("closes the area path down to the baseline", () => {
    const geometry = buildChartGeometry([point(50, 0), point(60, 1)], 0, 100, 640, 160, 6);
    expect(geometry!.areaPath.endsWith("Z")).toBe(true);
    expect(geometry!.areaPath).toContain("L6.00,154.00");
  });

  it("centers a single point horizontally", () => {
    const geometry = buildChartGeometry([point(50, 0)], 0, 100, 640, 160, 6);
    expect(geometry!.lastX).toBeCloseTo(6 + (640 - 12) / 2);
  });
});

describe("PredictionChart", () => {
  it("shows an empty state below two points", () => {
    render(<PredictionChart points={[point(700, 0)]} min={200} max={1200} />);
    expect(screen.getByTestId("chart-empty")).toBeInTheDocument();
  });

  it("renders an accessible SVG once there is history", () => {
    render(
      <PredictionChart
        points={[point(700, 0), point(750, 1), point(720, 2)]}
        min={200}
        max={1200}
      />,
    );
    const figure = screen.getByTestId("prediction-chart");
    expect(figure.querySelector("svg")).toHaveAttribute(
      "aria-label",
      expect.stringContaining("700.0"),
    );
    expect(figure.querySelectorAll("path").length).toBe(2);
  });
});

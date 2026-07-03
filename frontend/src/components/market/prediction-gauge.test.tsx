import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { gaugeFraction, PredictionGauge } from "./prediction-gauge";

describe("gaugeFraction", () => {
  it("maps values into [0,1] with clamping", () => {
    expect(gaugeFraction(200, 1200, 700)).toBeCloseTo(0.5);
    expect(gaugeFraction(200, 1200, 200)).toBe(0);
    expect(gaugeFraction(200, 1200, 1200)).toBe(1);
    expect(gaugeFraction(200, 1200, -100)).toBe(0);
    expect(gaugeFraction(200, 1200, 5000)).toBe(1);
  });

  it("handles degenerate ranges", () => {
    expect(gaugeFraction(5, 5, 5)).toBe(0);
  });
});

describe("PredictionGauge", () => {
  it("renders range labels and positions the prediction marker", () => {
    render(<PredictionGauge min={200} max={1200} prediction={950} liveCount={640} />);

    expect(screen.getByTestId("gauge-min")).toHaveTextContent("200");
    expect(screen.getByTestId("gauge-max")).toHaveTextContent("1,200");
    expect(screen.getByTestId("gauge-live-tick")).toHaveStyle({ left: "44%" });
  });

  it("omits optional markers when data is absent", () => {
    render(<PredictionGauge min={0} max={100} prediction={50} />);
    expect(screen.queryByTestId("gauge-live-tick")).not.toBeInTheDocument();
    expect(screen.queryByTestId("gauge-breakeven")).not.toBeInTheDocument();
  });

  it("shows the break-even diamond when provided", () => {
    render(<PredictionGauge min={0} max={1000} prediction={500} breakEven={750} />);
    expect(screen.getByTestId("gauge-breakeven")).toHaveStyle({ left: "75%" });
  });
});

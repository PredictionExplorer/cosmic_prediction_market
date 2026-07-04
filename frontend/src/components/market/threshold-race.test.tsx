import { render, screen } from "@testing-library/react";
import fc from "fast-check";
import { describe, expect, it } from "vitest";
import { ThresholdRace, trackFraction } from "./threshold-race";

describe("trackFraction", () => {
  it("property: always lands in [0, 1] and is monotone in the value", () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 0, max: 1_000_000 }),
        fc.integer({ min: 0, max: 2_000_000 }),
        fc.integer({ min: 0, max: 2_000_000 }),
        (threshold, a, b) => {
          const fa = trackFraction(threshold, a);
          const fb = trackFraction(threshold, b);
          expect(fa).toBeGreaterThanOrEqual(0);
          expect(fa).toBeLessThanOrEqual(1);
          if (a <= b) expect(fa).toBeLessThanOrEqual(fb + 1e-12);
        },
      ),
    );
  });

  it("keeps the finish line visibly inside the track", () => {
    const f = trackFraction(1_000, 1_000);
    expect(f).toBeGreaterThan(0.7);
    expect(f).toBeLessThan(1);
  });
});

describe("ThresholdRace", () => {
  it("shows current count and the target", () => {
    render(<ThresholdRace currentCount={640} threshold={800} />);
    expect(screen.getByTestId("race-current")).toHaveTextContent("640");
    expect(screen.getByTestId("race-target")).toHaveTextContent("800");
    expect(screen.getByTestId("threshold-race")).toHaveTextContent(/gestures vs last round/i);
  });

  it("announces the crossing", () => {
    render(<ThresholdRace currentCount={801} threshold={800} />);
    expect(screen.getByTestId("threshold-race")).toHaveTextContent(/threshold crossed — YES wins/i);
  });

  it("a tie is not a crossing", () => {
    render(<ThresholdRace currentCount={800} threshold={800} />);
    expect(screen.getByTestId("threshold-race")).not.toHaveTextContent(/crossed/i);
  });
});

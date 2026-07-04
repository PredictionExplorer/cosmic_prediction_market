import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { RoundSnapshot } from "@/lib/market";
import { ONE } from "@/lib/math";
import { MarketHero } from "./market-hero";

const SERIES = "0x1111111111111111111111111111111111111111" as const;

function snapshot(overrides: Partial<RoundSnapshot> = {}): RoundSnapshot {
  return {
    seriesAddress: SERIES,
    roundId: 5n,
    initialized: true,
    thresholdKnown: true,
    resolved: false,
    yesWon: false,
    threshold: 800n,
    currentCount: 500n,
    gameRoundNum: 5n,
    prevRoundCount: 800n,
    pool: {
      // NO-heavy pool: P(YES) = 3000/(1000+3000) = 75%.
      reserveYes: 1_000n * ONE,
      reserveNo: 3_000n * ONE,
      totalShares: 1_000n * ONE,
      accFeePerShare: 0n,
      feeReserve: 0n,
      feeWeight: 1_000n * ONE * 200n,
    },
    cstAddress: "0x2222222222222222222222222222222222222222",
    gameAddress: "0x3333333333333333333333333333333333333333",
    ...overrides,
  };
}

describe("MarketHero", () => {
  it("shows the pool-implied probability and the threshold to beat", () => {
    render(<MarketHero snapshot={snapshot()} history={[]} />);
    expect(screen.getByTestId("hero-probability")).toHaveTextContent("75.0%");
    expect(screen.getByTestId("hero-threshold")).toHaveTextContent("800");
    expect(screen.getByTestId("phase-badge")).toHaveTextContent(/live/i);
  });

  it("shows a dash and guidance when nothing is funded yet", () => {
    render(<MarketHero snapshot={snapshot({ pool: { reserveYes: 0n, reserveNo: 0n, totalShares: 0n, accFeePerShare: 0n, feeReserve: 0n, feeWeight: 0n }, initialized: false })} history={[]} />);
    expect(screen.getByTestId("hero-no-liquidity")).toBeInTheDocument();
    expect(screen.getByTestId("phase-badge")).toHaveTextContent(/awaiting first liquidity/i);
  });

  it("pins to 100% the moment the count crosses the threshold", () => {
    render(<MarketHero snapshot={snapshot({ currentCount: 801n })} history={[]} />);
    expect(screen.getByTestId("hero-probability")).toHaveTextContent("100.0%");
    expect(screen.getByTestId("phase-badge")).toHaveTextContent(/threshold crossed/i);
  });

  it("renders the resolved outcome with the final count", () => {
    render(<MarketHero snapshot={snapshot({ resolved: true, yesWon: true, currentCount: 950n })} history={[]} />);
    expect(screen.getByTestId("phase-badge")).toHaveTextContent(/resolved/i);
    expect(screen.getByTestId("hero-final-count")).toHaveTextContent("950");
    expect(screen.getByText(/Resolved: YES/i)).toBeInTheDocument();
  });

  it("labels a NO resolution honestly", () => {
    render(<MarketHero snapshot={snapshot({ resolved: true, yesWon: false, gameRoundNum: 6n })} history={[]} />);
    expect(screen.getByTestId("hero-probability")).toHaveTextContent("0.0%");
    expect(screen.getByText(/Resolved: NO/i)).toBeInTheDocument();
  });

  it("presents a next-round future market with its forming threshold", () => {
    render(
      <MarketHero
        snapshot={snapshot({
          roundId: 6n,
          gameRoundNum: 5n,
          thresholdKnown: false,
          threshold: 0n,
          currentCount: 0n,
          prevRoundCount: 640n,
        })}
        history={[]}
      />,
    );
    expect(screen.getByTestId("phase-badge")).toHaveTextContent(/future round/i);
    expect(screen.getByTestId("hero-threshold-forming")).toHaveTextContent(/640/);
    expect(screen.getByTestId("hero-threshold-forming")).toHaveTextContent(/round 5/i);
    // The pool still prices the market: early positions have a live number.
    expect(screen.getByTestId("hero-probability")).toHaveTextContent("75.0%");
    // No race to a meaningless zero — the pending strip renders instead.
    expect(screen.getByTestId("race-pending")).toBeInTheDocument();
  });

  it("tells far-future visitors when their threshold will lock", () => {
    render(
      <MarketHero
        snapshot={snapshot({
          roundId: 9n,
          gameRoundNum: 5n,
          thresholdKnown: false,
          threshold: 0n,
          currentCount: 0n,
          prevRoundCount: 0n,
        })}
        history={[]}
      />,
    );
    expect(screen.getByTestId("hero-threshold-unknown")).toHaveTextContent(/locks when round 8 ends/i);
    expect(screen.queryByTestId("hero-threshold")).not.toBeInTheDocument();
  });
});

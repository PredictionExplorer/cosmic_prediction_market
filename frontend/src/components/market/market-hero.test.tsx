import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { MarketSnapshot } from "@/lib/market";
import { ONE } from "@/lib/math";
import { MarketHero } from "./market-hero";

const BASE: MarketSnapshot = {
  address: "0x1111111111111111111111111111111111111111",
  round: 7n,
  minCount: 200n,
  maxCount: 1_200n,
  feeBps: 100n,
  reserveHigher: 10_000n * ONE,
  reserveLower: 10_000n * ONE,
  resolved: false,
  finalGestureCount: 0n,
  payoutPerHigher: 0n,
  creator: "0x2222222222222222222222222222222222222222",
  cstAddress: "0x3333333333333333333333333333333333333333",
  gameAddress: "0x4444444444444444444444444444444444444444",
  feesAccrued: 0n,
  gameRoundNum: 7n,
  liveGestureCount: 640n,
};

describe("MarketHero", () => {
  it("shows the live prediction, round and gesture count while live", () => {
    render(<MarketHero snapshot={BASE} history={[]} />);

    expect(screen.getByTestId("phase-badge")).toHaveTextContent(/live/i);
    expect(screen.getByText("Round 7")).toBeInTheDocument();
    expect(screen.getByTestId("live-count")).toHaveTextContent("640");
    expect(screen.getByTestId("animated-number")).toHaveTextContent("700.0");
    expect(screen.getByText(/the market predicts/i)).toBeInTheDocument();
  });

  it("switches to the awaiting-resolution banner when the round ends", () => {
    render(<MarketHero snapshot={{ ...BASE, gameRoundNum: 8n }} history={[]} />);
    expect(screen.getByTestId("phase-badge")).toHaveTextContent(/awaiting resolution/i);
  });

  it("shows the final outcome and payout rates once resolved", () => {
    render(
      <MarketHero
        snapshot={{
          ...BASE,
          resolved: true,
          gameRoundNum: 8n,
          finalGestureCount: 1_000n,
          payoutPerHigher: (8n * ONE) / 10n,
        }}
        history={[]}
      />,
    );

    expect(screen.getByTestId("phase-badge")).toHaveTextContent(/resolved/i);
    expect(screen.getByTestId("final-count")).toHaveTextContent("1,000");
    expect(screen.getByText(/final gesture count/i)).toBeInTheDocument();
    // Payout sentence shows both rates.
    expect(screen.getByText("0.8")).toBeInTheDocument();
    expect(screen.getByText("0.2")).toBeInTheDocument();
  });
});

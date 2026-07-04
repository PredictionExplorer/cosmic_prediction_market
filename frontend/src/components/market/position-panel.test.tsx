import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { RoundSnapshot, UserSnapshot } from "@/lib/market";
import { ONE } from "@/lib/math";
import { PositionPanel, type PositionPanelProps } from "./position-panel";

const SERIES = "0x1111111111111111111111111111111111111111" as const;

function snapshot(overrides: Partial<RoundSnapshot> = {}): RoundSnapshot {
  return {
    seriesAddress: SERIES,
    roundId: 5n,
    initialized: true,
    resolved: false,
    yesWon: false,
    threshold: 800n,
    currentCount: 500n,
    gameRoundNum: 5n,
    pool: {
      reserveYes: 1_000n * ONE,
      reserveNo: 1_000n * ONE,
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

function user(overrides: Partial<UserSnapshot> = {}): UserSnapshot {
  return {
    address: "0x4444444444444444444444444444444444444444",
    yesBalance: 100n * ONE,
    noBalance: 40n * ONE,
    cstBalance: 1_000n * ONE,
    cstAllowance: 0n,
    lpShares: 0n,
    lpPendingFees: 0n,
    lpDeclaredFeeBps: 0,
    ...overrides,
  };
}

function renderPanel(overrides: Partial<PositionPanelProps> = {}) {
  const props: PositionPanelProps = {
    snapshot: snapshot(),
    user: user(),
    pendingAction: null,
    onRedeemSets: vi.fn().mockResolvedValue(true),
    onClaim: vi.fn().mockResolvedValue(true),
    ...overrides,
  };
  const utils = render(<PositionPanel {...props} />);
  return { props, ...utils };
}

describe("PositionPanel", () => {
  it("renders nothing without a position", () => {
    renderPanel({ user: user({ yesBalance: 0n, noBalance: 0n }) });
    expect(screen.queryByTestId("position-panel")).not.toBeInTheDocument();
  });

  it("shows balances marked at the pool probability while live", () => {
    renderPanel();
    expect(screen.getByTestId("yes-balance")).toHaveTextContent("100");
    expect(screen.getByTestId("no-balance")).toHaveTextContent("40");
    // 50% pool: value = 100*0.5 + 40*0.5 = 70.
    expect(screen.getByTestId("position-value")).toHaveTextContent("70");
  });

  it("redeems complete sets while live", async () => {
    const u = userEvent.setup();
    const { props } = renderPanel();
    await u.click(screen.getByTestId("redeem-button"));
    expect(props.onRedeemSets).toHaveBeenCalledWith(40n * ONE); // min(yes, no)
  });

  it("explains a decided outcome and values YES at par", () => {
    renderPanel({ snapshot: snapshot({ currentCount: 801n }) });
    expect(screen.getByTestId("decided-note")).toBeInTheDocument();
    expect(screen.getByTestId("position-value")).toHaveTextContent("100");
  });

  it("claims the exact winning balance after resolution", async () => {
    const u = userEvent.setup();
    const { props } = renderPanel({ snapshot: snapshot({ resolved: true, yesWon: true }) });
    const button = screen.getByTestId("claim-button");
    expect(button).toHaveTextContent("100");
    await u.click(button);
    expect(props.onClaim).toHaveBeenCalled();
    expect(screen.queryByTestId("redeem-button")).not.toBeInTheDocument();
  });

  it("shows zero claimable when the user lost", () => {
    renderPanel({ snapshot: snapshot({ resolved: true, yesWon: false }) });
    expect(screen.getByTestId("claim-button")).toHaveTextContent("40");
  });
});

import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { MarketSnapshot, UserSnapshot } from "@/lib/market";
import { ONE } from "@/lib/math";
import { PositionPanel, type PositionPanelProps } from "./position-panel";

const LIVE: MarketSnapshot = {
  address: "0x1111111111111111111111111111111111111111",
  round: 3n,
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
  gameRoundNum: 3n,
  liveGestureCount: 700n,
};

const RESOLVED: MarketSnapshot = {
  ...LIVE,
  resolved: true,
  gameRoundNum: 4n,
  finalGestureCount: 1_000n,
  payoutPerHigher: (8n * ONE) / 10n,
};

const USER: UserSnapshot = {
  address: "0x5555555555555555555555555555555555555555",
  higherBalance: 100n * ONE,
  lowerBalance: 0n,
  cstBalance: 50n * ONE,
  cstAllowance: 0n,
};

function renderPanel(overrides: Partial<PositionPanelProps> = {}) {
  const props: PositionPanelProps = {
    snapshot: LIVE,
    user: USER,
    breakEven: 850,
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
    renderPanel({ user: { ...USER, higherBalance: 0n, lowerBalance: 0n } });
    expect(screen.queryByTestId("position-panel")).not.toBeInTheDocument();
  });

  it("shows balances and the live-marked value", () => {
    renderPanel();
    expect(screen.getByTestId("higher-balance")).toHaveTextContent("100");
    expect(screen.getByTestId("lower-balance")).toHaveTextContent("0");
    // 100 HIGHER at live count 700 ⇒ f = 0.5 ⇒ 50 CST.
    expect(screen.getByTestId("position-value")).toHaveTextContent("50");
  });

  it("what-if slider reprices the position at any hypothetical count", () => {
    renderPanel();
    const slider = screen.getByTestId("what-if-slider");

    fireEvent.change(slider, { target: { value: "1200" } });
    expect(screen.getByTestId("what-if-count")).toHaveTextContent("1,200");
    expect(screen.getByTestId("what-if-value")).toHaveTextContent("100");

    fireEvent.change(slider, { target: { value: "200" } });
    expect(screen.getByTestId("what-if-value")).toHaveTextContent("0");
  });

  it("redeems complete sets when holding both sides", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel({
      user: { ...USER, higherBalance: 30n * ONE, lowerBalance: 12n * ONE },
    });

    expect(screen.getByText(/complete sets/i)).toBeInTheDocument();
    await user.click(screen.getByTestId("redeem-button"));
    expect(props.onRedeemSets).toHaveBeenCalledWith(12n * ONE);
  });

  it("hides the redeem row for one-sided positions", () => {
    renderPanel();
    expect(screen.queryByTestId("redeem-button")).not.toBeInTheDocument();
  });

  it("claims at the fixed rate once resolved", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel({ snapshot: RESOLVED });

    // 100 HIGHER * 0.8 = 80 CST claimable; slider is gone.
    const claim = screen.getByTestId("claim-button");
    expect(claim).toHaveTextContent("80");
    expect(screen.queryByTestId("what-if-slider")).not.toBeInTheDocument();

    await user.click(claim);
    expect(props.onClaim).toHaveBeenCalled();
  });

  it("shows a break-even hint for directional positions", () => {
    renderPanel();
    expect(screen.getByTestId("break-even")).toHaveTextContent(/above/i);
    expect(screen.getByTestId("break-even")).toHaveTextContent("850");
  });

  it("clamps the displayed break-even into the market range", () => {
    renderPanel({ breakEven: 99_999 });
    expect(screen.getByTestId("break-even")).toHaveTextContent("1,200");
  });

  it("omits the break-even hint when unknown", () => {
    renderPanel({ breakEven: null });
    expect(screen.queryByTestId("break-even")).not.toBeInTheDocument();
  });

  it("no what-if or claim while pending action disables buttons", () => {
    renderPanel({
      snapshot: RESOLVED,
      pendingAction: "claim",
    });
    expect(screen.getByTestId("claim-button")).toBeDisabled();
  });
});

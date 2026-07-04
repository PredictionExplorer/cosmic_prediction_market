import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { LpPosition } from "@/lib/market";
import { DEAD_SHARES, joinPool, minTokensOutForSlippage, ONE, openPool, removeLiquidity, type TierPool } from "@/lib/math";
import { LiquidityPanel, type LiquidityPanelProps } from "./liquidity-panel";

const LIQ = 10_000n * ONE;

function tierPool(feeBps: number, funded: boolean): TierPool {
  return funded
    ? { feeBps, pool: { reserveYes: LIQ, reserveNo: LIQ / 2n, totalShares: LIQ, accFeePerShare: 0n, feeReserve: 0n } }
    : { feeBps, pool: { reserveYes: 0n, reserveNo: 0n, totalShares: 0n, accFeePerShare: 0n, feeReserve: 0n } };
}

function renderPanel(overrides: Partial<LiquidityPanelProps> = {}) {
  const props: LiquidityPanelProps = {
    pools: [tierPool(100, true), tierPool(200, false), tierPool(500, false)],
    lpPositions: [],
    canAdd: true,
    balance: 100_000n * ONE,
    allowance: 10_000_000n * ONE,
    pendingAction: null,
    onConnect: vi.fn(),
    onApprove: vi.fn().mockResolvedValue(true),
    onAdd: vi.fn().mockResolvedValue(true),
    onRemove: vi.fn().mockResolvedValue(true),
    onClaimFees: vi.fn().mockResolvedValue(true),
    ...overrides,
  };
  const utils = render(<LiquidityPanel {...props} />);
  return { props, ...utils };
}

describe("LiquidityPanel — adding", () => {
  it("joins a funded pool at its ratio and submits with a share floor", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel();

    await user.type(screen.getByTestId("lp-amount-input"), "100");
    const preview = joinPool(tierPool(100, true).pool, 100n * ONE);
    expect(screen.getByTestId("lp-preview-shares")).toBeInTheDocument();

    await user.click(screen.getByTestId("lp-add-submit"));
    expect(props.onAdd).toHaveBeenCalledWith(
      100,
      100n * ONE,
      5_000n, // ignored by the contract when joining
      minTokensOutForSlippage(preview!.sharesOut, 50),
    );
  });

  it("shows the excess tokens a skewed join returns", async () => {
    const user = userEvent.setup();
    renderPanel();
    await user.type(screen.getByTestId("lp-amount-input"), "100");
    const preview = joinPool(tierPool(100, true).pool, 100n * ONE);
    expect(preview!.excessNo).toBeGreaterThan(0n);
    expect(screen.getByTestId("lp-preview-excess").textContent).toContain("NO");
  });

  it("first LP into an empty tier picks the opening odds", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel();

    await user.click(screen.getByTestId("lp-tier-200")); // empty pool
    expect(screen.getByTestId("lp-odds")).toBeInTheDocument();

    // Slide the opening odds to 30% YES.
    const slider = screen.getByTestId("lp-odds-slider");
    // Range inputs don't support typing; set via change event.
    await user.click(slider);
    // fireEvent-based approach through userEvent isn't available for range;
    // fall back to the raw change.
    const { fireEvent } = await import("@testing-library/react");
    fireEvent.change(slider, { target: { value: "30" } });
    expect(screen.getByTestId("lp-odds-value")).toHaveTextContent("30%");

    await user.type(screen.getByTestId("lp-amount-input"), "10");
    const preview = openPool(10n * ONE, 3_000n);
    expect(screen.getByTestId("lp-preview-shares").textContent).not.toBe("");

    await user.click(screen.getByTestId("lp-add-submit"));
    expect(props.onAdd).toHaveBeenCalledWith(
      200,
      10n * ONE,
      3_000n,
      minTokensOutForSlippage(preview.sharesOut, 50),
    );
  });

  it("rejects first deposits below the contract minimum", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel();
    await user.click(screen.getByTestId("lp-tier-200"));
    await user.type(screen.getByTestId("lp-amount-input"), "0.0000001");
    expect(screen.getByTestId("lp-add-error")).toHaveTextContent(/minimum/i);
    await user.click(screen.getByTestId("lp-add-submit"));
    expect(props.onAdd).not.toHaveBeenCalled();
  });

  it("routes through approval when allowance is too low", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel({ allowance: 0n });
    await user.type(screen.getByTestId("lp-amount-input"), "10");
    await user.click(screen.getByTestId("lp-add-submit"));
    expect(props.onApprove).toHaveBeenCalledWith(10n * ONE);
    expect(props.onAdd).not.toHaveBeenCalled();
  });

  it("hides the add flow when the round no longer accepts liquidity", () => {
    renderPanel({ canAdd: false });
    expect(screen.getByTestId("lp-add-closed")).toBeInTheDocument();
    expect(screen.queryByTestId("lp-amount-input")).not.toBeInTheDocument();
  });

  it("prompts to connect when no wallet is present", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel({ balance: null, allowance: null });
    await user.type(screen.getByTestId("lp-amount-input"), "10");
    await user.click(screen.getByTestId("lp-add-submit"));
    expect(props.onConnect).toHaveBeenCalled();
  });
});

describe("LiquidityPanel — position, removing, fees", () => {
  const position: LpPosition = { feeBps: 100, shares: 4_000n * ONE, pendingFees: 12n * ONE };

  it("shows the position and claims fees", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel({ lpPositions: [position] });

    expect(screen.getByTestId("lp-position")).toBeInTheDocument();
    expect(screen.getByTestId("lp-pending-fees")).toHaveTextContent("12");
    await user.click(screen.getByTestId("claim-fees-button"));
    expect(props.onClaimFees).toHaveBeenCalledWith(100);
  });

  it("previews and submits a partial removal with slippage floors", async () => {
    const user = userEvent.setup();
    const { props } = renderPanel({ lpPositions: [position] });

    await user.click(screen.getByTestId("lp-mode-remove"));
    const { fireEvent } = await import("@testing-library/react");
    fireEvent.change(screen.getByTestId("lp-remove-slider"), { target: { value: "50" } });
    expect(screen.getByTestId("lp-remove-pct")).toHaveTextContent("50%");

    const shares = (position.shares * 50n) / 100n;
    const preview = removeLiquidity(tierPool(100, true).pool, shares);
    expect(screen.getByTestId("lp-remove-preview").textContent).toContain("YES");

    await user.click(screen.getByTestId("lp-remove-submit"));
    expect(props.onRemove).toHaveBeenCalledWith(
      100,
      shares,
      minTokensOutForSlippage(preview.yesOut, 50),
      minTokensOutForSlippage(preview.noOut, 50),
    );
  });

  it("explains when there is nothing to remove", async () => {
    const user = userEvent.setup();
    renderPanel();
    await user.click(screen.getByTestId("lp-mode-remove"));
    expect(screen.getByTestId("lp-no-position")).toBeInTheDocument();
  });

  it("mentions the dead-share lock for first deposits", async () => {
    const user = userEvent.setup();
    renderPanel();
    await user.click(screen.getByTestId("lp-tier-500"));
    await user.type(screen.getByTestId("lp-amount-input"), "10");
    expect(screen.getByTestId("lp-add-preview").textContent).toContain(DEAD_SHARES.toString());
  });
});

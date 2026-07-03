"use client";

import { ArrowDown, ArrowUp, Settings2 } from "lucide-react";
import { useMemo, useState } from "react";
import { formatUnits } from "viem";
import { appConfig } from "@/lib/config";
import { formatCount, formatCst, parseCstInput } from "@/lib/format";
import type { MarketRange, PoolState } from "@/lib/math";
import {
  entryCount,
  minTokensOutForSlippage,
  predictedCountFloat,
  quoteBet,
  takeFee,
  type BetSide,
} from "@/lib/math";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";

export interface BetPanelProps {
  range: MarketRange;
  pool: PoolState;
  feeBps: bigint;
  /** Null when no wallet is connected. */
  balance: bigint | null;
  allowance: bigint | null;
  pendingAction: "approve" | "bet" | null;
  onConnect: () => void;
  onApprove: (amount: bigint) => Promise<boolean>;
  onBet: (side: BetSide, cstIn: bigint, minTokensOut: bigint) => Promise<boolean>;
}

const SLIPPAGE_PRESETS_BPS = [10, 50, 100] as const;

/**
 * Place a bet: pick a side, type CST, see the exact quote (client-side pure
 * math, mirrors the contract), approve if needed, bet with slippage guard.
 */
export function BetPanel({
  range,
  pool,
  feeBps,
  balance,
  allowance,
  pendingAction,
  onConnect,
  onApprove,
  onBet,
}: BetPanelProps) {
  const [side, setSide] = useState<BetSide>("higher");
  const [input, setInput] = useState("");
  const [slippageBps, setSlippageBps] = useState<number>(50);
  const [showSettings, setShowSettings] = useState(false);

  const parsed = parseCstInput(input);
  const amount = parsed.value;

  const quote = useMemo(() => {
    if (amount === null) return null;
    const tokensOut = quoteBet(side, pool, amount, feeBps);
    const entry = entryCount(range, side, amount, tokensOut);
    const minOut = minTokensOutForSlippage(tokensOut, slippageBps);
    const { fee } = takeFee(amount, feeBps);
    // Max multiple if the count lands fully on your side of the range.
    const multiple = Number(tokensOut) / Number(amount);
    return { tokensOut, entry, minOut, fee, multiple };
  }, [amount, side, pool, feeBps, range, slippageBps]);

  const prediction = predictedCountFloat(range, pool);
  const connected = balance !== null;
  const insufficient = connected && amount !== null && amount > (balance ?? 0n);
  const needsApproval = connected && amount !== null && (allowance ?? 0n) < amount;
  const busy = pendingAction !== null;

  const submit = async () => {
    if (!connected) {
      onConnect();
      return;
    }
    if (amount === null || quote === null || insufficient) return;
    if (needsApproval) {
      await onApprove(amount);
      return;
    }
    const ok = await onBet(side, amount, quote.minOut);
    if (ok) setInput("");
  };

  const sideColor = side === "higher" ? "text-higher" : "text-lower";

  let buttonLabel: string;
  if (!connected) buttonLabel = "Connect wallet to bet";
  else if (amount === null) buttonLabel = "Enter an amount";
  else if (insufficient) buttonLabel = "Insufficient CST balance";
  else if (needsApproval) buttonLabel = "Approve CST";
  else buttonLabel = side === "higher" ? "Bet HIGHER" : "Bet LOWER";

  return (
    <Card accent={side} className="p-5" data-testid="bet-panel">
      <div className="flex items-center justify-between">
        <h2 className="font-display text-lg font-semibold">Place your bet</h2>
        <button
          aria-label="Slippage settings"
          onClick={() => setShowSettings((v) => !v)}
          className={`rounded-lg p-1.5 transition-colors hover:bg-surface-2 ${showSettings ? "text-nova-bright" : "text-ink-faint"}`}
        >
          <Settings2 className="size-4" />
        </button>
      </div>

      {showSettings && (
        <div className="mt-3 flex items-center justify-between rounded-xl border border-line bg-surface-2/50 px-3 py-2" data-testid="slippage-settings">
          <span className="text-xs text-ink-dim">Max slippage</span>
          <div className="flex gap-1">
            {SLIPPAGE_PRESETS_BPS.map((bps) => (
              <button
                key={bps}
                onClick={() => setSlippageBps(bps)}
                className={[
                  "rounded-lg px-2.5 py-1 font-mono text-xs transition-colors",
                  slippageBps === bps ? "bg-nova/20 text-nova-bright" : "text-ink-faint hover:text-ink",
                ].join(" ")}
              >
                {(bps / 100).toLocaleString("en-US")}%
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Side selector */}
      <div className="mt-4 grid grid-cols-2 gap-2" role="tablist" aria-label="Bet direction">
        <button
          role="tab"
          aria-selected={side === "higher"}
          data-testid="tab-higher"
          onClick={() => setSide("higher")}
          className={[
            "flex items-center justify-center gap-2 rounded-xl border py-3 font-display text-sm font-bold uppercase tracking-wide transition-all",
            side === "higher"
              ? "border-higher/60 bg-higher/12 text-higher shadow-glow-higher"
              : "border-line text-ink-faint hover:border-line-strong hover:text-ink-dim",
          ].join(" ")}
        >
          <ArrowUp className="size-4" aria-hidden /> Higher
        </button>
        <button
          role="tab"
          aria-selected={side === "lower"}
          data-testid="tab-lower"
          onClick={() => setSide("lower")}
          className={[
            "flex items-center justify-center gap-2 rounded-xl border py-3 font-display text-sm font-bold uppercase tracking-wide transition-all",
            side === "lower"
              ? "border-lower/60 bg-lower/12 text-lower shadow-glow-lower"
              : "border-line text-ink-faint hover:border-line-strong hover:text-ink-dim",
          ].join(" ")}
        >
          <ArrowDown className="size-4" aria-hidden /> Lower
        </button>
      </div>

      <p className="mt-2 text-center text-xs text-ink-faint">
        You win if the final count is{" "}
        <span className={`font-semibold ${sideColor}`}>
          {side === "higher" ? "above" : "below"}
        </span>{" "}
        your entry of ~{formatCount(quote?.entry ?? prediction)} gestures
      </p>

      {/* Amount */}
      <div className="mt-4 rounded-xl border border-line bg-space/50 p-3 focus-within:border-nova/50">
        <div className="flex items-center justify-between text-[11px] text-ink-faint">
          <label htmlFor="bet-amount">Amount</label>
          {connected && (
            <button
              className="transition-colors hover:text-nova-bright"
              onClick={() => setInput(balance && balance > 0n ? formatUnits(balance, 18) : "")}
              data-testid="max-button"
            >
              Balance: <span className="font-mono">{formatCst(balance ?? 0n)}</span> · MAX
            </button>
          )}
        </div>
        <div className="mt-1 flex items-center gap-2">
          <input
            id="bet-amount"
            data-testid="amount-input"
            inputMode="decimal"
            autoComplete="off"
            placeholder="0.0"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            className="w-full bg-transparent font-display text-2xl font-semibold text-ink outline-none placeholder:text-ink-faint/50"
          />
          <span className="rounded-lg bg-surface-2 px-2.5 py-1 font-mono text-xs font-semibold text-ink-dim">
            CST
          </span>
        </div>
        {parsed.error && (
          <p className="mt-1 text-xs text-lower" role="alert" data-testid="input-error">
            {parsed.error}
          </p>
        )}
      </div>

      {/* Quote */}
      {quote !== null && !parsed.error && (
        <dl className="mt-4 space-y-2 rounded-xl border border-line bg-surface-2/40 p-3 text-xs" data-testid="quote-box">
          <div className="flex justify-between">
            <dt className="text-ink-faint">You receive</dt>
            <dd className={`font-mono font-semibold ${sideColor}`} data-testid="quote-tokens">
              {formatCst(quote.tokensOut)} {side.toUpperCase()}
            </dd>
          </div>
          <div className="flex justify-between">
            <dt className="text-ink-faint">Your entry (break-even)</dt>
            <dd className="font-mono text-ink" data-testid="quote-entry">
              {quote.entry === null ? "—" : `${formatCount(quote.entry)} gestures`}
            </dd>
          </div>
          <div className="flex justify-between">
            <dt className="text-ink-faint">Max payout (up to {quote.multiple.toLocaleString("en-US", { maximumFractionDigits: 2 })}×)</dt>
            <dd className="font-mono text-ink" data-testid="quote-max-payout">
              {formatCst(quote.tokensOut)} CST
            </dd>
          </div>
          <div className="flex justify-between">
            <dt className="text-ink-faint">Fee</dt>
            <dd className="font-mono text-ink-dim">{formatCst(quote.fee)} CST</dd>
          </div>
          <div className="flex justify-between">
            <dt className="text-ink-faint">Min received (slippage {(slippageBps / 100).toLocaleString("en-US")}%)</dt>
            <dd className="font-mono text-ink-dim">{formatCst(quote.minOut)}</dd>
          </div>
        </dl>
      )}

      <Button
        className="mt-4 w-full"
        size="lg"
        variant={!connected ? "nova" : needsApproval ? "nova" : side}
        disabled={connected && (amount === null || insufficient || !!parsed.error)}
        loading={busy}
        onClick={() => void submit()}
        data-testid="bet-submit"
      >
        {busy ? (pendingAction === "approve" ? "Approving…" : "Confirming…") : buttonLabel}
      </Button>

      <p className="mt-3 text-center text-[11px] leading-relaxed text-ink-faint">
        Bets are placed in CST on {appConfig.chain.name}. 1 winning-side token pays up to 1 CST at
        resolution. Exit early any time by betting the other side and redeeming pairs.
      </p>
    </Card>
  );
}

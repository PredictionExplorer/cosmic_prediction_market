"use client";

import { Droplets, HandCoins } from "lucide-react";
import { useMemo, useState } from "react";
import { formatBps, formatCst, parseCstInput } from "@/lib/format";
import type { LpPosition } from "@/lib/market";
import type { TierPool } from "@/lib/math";
import {
  DEAD_SHARES,
  joinPool,
  MIN_INITIAL_LIQUIDITY,
  minTokensOutForSlippage,
  openPool,
  probabilityFloat,
  removeLiquidity,
} from "@/lib/math";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";

export interface LiquidityPanelProps {
  pools: readonly TierPool[];
  lpPositions: readonly LpPosition[];
  /** Whether the round currently accepts new liquidity (live phase only). */
  canAdd: boolean;
  /** Null when no wallet is connected. */
  balance: bigint | null;
  allowance: bigint | null;
  pendingAction: "approve" | "addLiquidity" | "removeLiquidity" | "claimFees" | null;
  onConnect: () => void;
  onApprove: (amount: bigint) => Promise<boolean>;
  onAdd: (feeBps: number, cstIn: bigint, initialYesProbBps: bigint, minSharesOut: bigint) => Promise<boolean>;
  onRemove: (feeBps: number, shares: bigint, minYesOut: bigint, minNoOut: bigint) => Promise<boolean>;
  onClaimFees: (feeBps: number) => Promise<boolean>;
}

const SHARE_SLIPPAGE_BPS = 50;

/**
 * Provide liquidity into the fee tier of your choice and earn that tier's fee
 * on every bet. The first LP of a pool opens it at their chosen YES odds;
 * later deposits join at the pool's current ratio. Removing works at any
 * time — live, decided, or after resolution.
 */
export function LiquidityPanel({
  pools,
  lpPositions,
  canAdd,
  balance,
  allowance,
  pendingAction,
  onConnect,
  onApprove,
  onAdd,
  onRemove,
  onClaimFees,
}: LiquidityPanelProps) {
  const [tier, setTier] = useState<number>(pools[0]?.feeBps ?? 100);
  const [mode, setMode] = useState<"add" | "remove">("add");
  const [input, setInput] = useState("");
  const [probPct, setProbPct] = useState(50);
  const [removePct, setRemovePct] = useState(100);

  const selected = pools.find((p) => p.feeBps === tier) ?? pools[0];
  const position = lpPositions.find((p) => p.feeBps === tier);
  const poolOpen = (selected?.pool.totalShares ?? 0n) > 0n;

  const parsed = parseCstInput(input);
  const amount = parsed.value;

  const addPreview = useMemo(() => {
    if (!selected || amount === null) return null;
    if (!poolOpen) {
      if (amount < MIN_INITIAL_LIQUIDITY) return { error: "Below the minimum first deposit (0.001 CST)" } as const;
      const result = openPool(amount, BigInt(probPct * 100));
      return { shares: result.sharesOut, excessYes: result.excessYes, excessNo: result.excessNo, error: null } as const;
    }
    const result = joinPool(selected.pool, amount);
    if (result === null) return { error: "Deposit too small for this pool" } as const;
    return { shares: result.sharesOut, excessYes: result.excessYes, excessNo: result.excessNo, error: null } as const;
  }, [selected, amount, poolOpen, probPct]);

  const removePreview = useMemo(() => {
    if (!selected || !position || position.shares === 0n) return null;
    const shares = (position.shares * BigInt(removePct)) / 100n;
    if (shares === 0n) return null;
    const { yesOut, noOut } = removeLiquidity(selected.pool, shares);
    return { shares, yesOut, noOut };
  }, [selected, position, removePct]);

  const connected = balance !== null;
  const insufficient = connected && amount !== null && amount > (balance ?? 0n);
  const needsApproval = connected && amount !== null && (allowance ?? 0n) < amount;
  const poolProb = selected ? probabilityFloat(selected.pool) : null;

  const submitAdd = async () => {
    if (!connected) {
      onConnect();
      return;
    }
    if (!selected || amount === null || !addPreview || addPreview.error !== null || insufficient) return;
    if (needsApproval) {
      await onApprove(amount);
      return;
    }
    const minShares = minTokensOutForSlippage(addPreview.shares, SHARE_SLIPPAGE_BPS);
    const ok = await onAdd(selected.feeBps, amount, BigInt(probPct * 100), minShares);
    if (ok) setInput("");
  };

  const submitRemove = async () => {
    if (!selected || !removePreview) return;
    const minYes = minTokensOutForSlippage(removePreview.yesOut, SHARE_SLIPPAGE_BPS);
    const minNo = minTokensOutForSlippage(removePreview.noOut, SHARE_SLIPPAGE_BPS);
    await onRemove(selected.feeBps, removePreview.shares, minYes, minNo);
  };

  let addLabel: string;
  if (!connected) addLabel = "Connect wallet to provide";
  else if (amount === null) addLabel = "Enter an amount";
  else if (insufficient) addLabel = "Insufficient CST balance";
  else if (needsApproval) addLabel = "Approve CST";
  else if (!poolOpen) addLabel = "Open pool & provide";
  else addLabel = "Add liquidity";

  return (
    <Card accent="nova" className="p-5" data-testid="liquidity-panel">
      <div className="flex items-center justify-between">
        <h2 className="flex items-center gap-2 font-display text-lg font-semibold">
          <Droplets className="size-4 text-nova-bright" aria-hidden />
          Provide liquidity
        </h2>
        <div className="flex rounded-lg border border-line p-0.5 text-xs" role="tablist" aria-label="Liquidity mode">
          {(["add", "remove"] as const).map((m) => (
            <button
              key={m}
              role="tab"
              aria-selected={mode === m}
              data-testid={`lp-mode-${m}`}
              onClick={() => setMode(m)}
              className={[
                "rounded-md px-2.5 py-1 capitalize transition-colors",
                mode === m ? "bg-nova/15 text-nova-bright" : "text-ink-faint hover:text-ink",
              ].join(" ")}
            >
              {m}
            </button>
          ))}
        </div>
      </div>

      {/* Tier picker: choose the fee you're willing to accept. */}
      <div className="mt-4">
        <p className="text-[11px] text-ink-faint">Your fee — earned on every bet in your pool</p>
        <div className="mt-1.5 grid grid-cols-3 gap-1.5" data-testid="lp-tier-selector">
          {pools.map(({ feeBps, pool }) => {
            const pos = lpPositions.find((p) => p.feeBps === feeBps);
            const active = tier === feeBps;
            return (
              <button
                key={feeBps}
                data-testid={`lp-tier-${feeBps}`}
                aria-pressed={active}
                onClick={() => setTier(feeBps)}
                className={[
                  "rounded-xl border px-2 py-2 text-left transition-colors",
                  active ? "border-nova/60 bg-nova/10" : "border-line hover:border-line-strong",
                ].join(" ")}
              >
                <p className={`font-mono text-sm font-semibold ${active ? "text-nova-bright" : "text-ink"}`}>
                  {formatBps(BigInt(feeBps))}
                </p>
                <p className="mt-0.5 truncate text-[10px] text-ink-faint">
                  {pool.totalShares === 0n ? "empty" : `${formatCst(pool.reserveYes + pool.reserveNo)} tokens`}
                  {pos && pos.shares > 0n ? " · yours" : ""}
                </p>
              </button>
            );
          })}
        </div>
      </div>

      {/* Your position in the selected tier */}
      {position && (position.shares > 0n || position.pendingFees > 0n) && (
        <div
          className="mt-3 flex items-center justify-between gap-3 rounded-xl border border-line bg-surface-2/40 px-3 py-2.5"
          data-testid="lp-position"
        >
          <div className="text-xs text-ink-dim">
            <span className="font-mono text-ink">{formatCst(position.shares)}</span> shares ·{" "}
            <span className="font-mono text-higher" data-testid="lp-pending-fees">
              {formatCst(position.pendingFees)}
            </span>{" "}
            CST fees earned
          </div>
          <Button
            variant="outline"
            size="sm"
            disabled={position.pendingFees === 0n}
            loading={pendingAction === "claimFees"}
            onClick={() => void onClaimFees(tier)}
            data-testid="claim-fees-button"
          >
            <HandCoins className="size-3.5" aria-hidden />
            Claim fees
          </Button>
        </div>
      )}

      {mode === "add" ? (
        !canAdd ? (
          <p className="mt-4 rounded-xl border border-dashed border-line p-4 text-center text-xs text-ink-faint" data-testid="lp-add-closed">
            Adding liquidity is closed for this round (it&apos;s decided, ended, or resolved). You can still remove
            and claim fees at any time.
          </p>
        ) : (
          <>
            <div className="mt-4 rounded-xl border border-line bg-space/50 p-3 focus-within:border-nova/50">
              <div className="flex items-center justify-between text-[11px] text-ink-faint">
                <label htmlFor="lp-amount">Amount</label>
                {connected && (
                  <span>
                    Balance: <span className="font-mono">{formatCst(balance ?? 0n)}</span>
                  </span>
                )}
              </div>
              <div className="mt-1 flex items-center gap-2">
                <input
                  id="lp-amount"
                  data-testid="lp-amount-input"
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
                <p className="mt-1 text-xs text-lower" role="alert">
                  {parsed.error}
                </p>
              )}
            </div>

            {/* First LP sets the opening odds. */}
            {!poolOpen && (
              <div className="mt-3 rounded-xl border border-line bg-surface-2/40 p-3" data-testid="lp-odds">
                <div className="flex items-baseline justify-between text-xs">
                  <span className="text-ink-faint">Opening odds — chance of YES</span>
                  <span className="font-mono font-semibold text-ink" data-testid="lp-odds-value">
                    {probPct}%
                  </span>
                </div>
                <input
                  type="range"
                  className="cosmic-range mt-2"
                  min={1}
                  max={99}
                  value={probPct}
                  onChange={(e) => setProbPct(Number(e.target.value))}
                  aria-label="Opening YES probability"
                  data-testid="lp-odds-slider"
                />
                <p className="mt-1.5 text-[11px] leading-relaxed text-ink-faint">
                  You&apos;re the first LP in this pool: pick where the odds open. Misjudged odds are free money for
                  arbitrageurs, so open near your honest estimate.
                </p>
              </div>
            )}

            {addPreview && "error" in addPreview && addPreview.error !== null && (
              <p className="mt-3 text-xs text-lower" role="alert" data-testid="lp-add-error">
                {addPreview.error}
              </p>
            )}
            {addPreview && addPreview.error === null && (
              <dl className="mt-3 space-y-2 rounded-xl border border-line bg-surface-2/40 p-3 text-xs" data-testid="lp-add-preview">
                <div className="flex justify-between">
                  <dt className="text-ink-faint">LP shares</dt>
                  <dd className="font-mono font-semibold text-ink" data-testid="lp-preview-shares">
                    {formatCst(addPreview.shares)}
                  </dd>
                </div>
                {(addPreview.excessYes > 0n || addPreview.excessNo > 0n) && (
                  <div className="flex justify-between">
                    <dt className="text-ink-faint">Returned to you</dt>
                    <dd className="font-mono text-ink-dim" data-testid="lp-preview-excess">
                      {addPreview.excessYes > 0n
                        ? `${formatCst(addPreview.excessYes)} YES`
                        : `${formatCst(addPreview.excessNo)} NO`}
                    </dd>
                  </div>
                )}
                {!poolOpen && (
                  <div className="flex justify-between">
                    <dt className="text-ink-faint">Locked forever (anti-attack)</dt>
                    <dd className="font-mono text-ink-dim">{DEAD_SHARES.toString()} share wei</dd>
                  </div>
                )}
              </dl>
            )}

            <Button
              className="mt-4 w-full"
              size="lg"
              variant="nova"
              disabled={connected && (amount === null || insufficient || !!parsed.error || addPreview?.error != null)}
              loading={pendingAction === "approve" || pendingAction === "addLiquidity"}
              onClick={() => void submitAdd()}
              data-testid="lp-add-submit"
            >
              {addLabel}
            </Button>

            <p className="mt-3 text-center text-[11px] leading-relaxed text-ink-faint">
              LP risk: the gesture count is public, so late traders are informed — fees are your compensation. Size
              accordingly and withdraw when the round stops being uncertain.
            </p>
          </>
        )
      ) : (
        <>
          {!position || position.shares === 0n ? (
            <p className="mt-4 rounded-xl border border-dashed border-line p-4 text-center text-xs text-ink-faint" data-testid="lp-no-position">
              No LP position in the {formatBps(BigInt(tier))} pool{poolProb !== null ? "" : " — it hasn't been opened yet"}.
            </p>
          ) : (
            <>
              <div className="mt-4 rounded-xl border border-line bg-surface-2/40 p-3" data-testid="lp-remove-box">
                <div className="flex items-baseline justify-between text-xs">
                  <span className="text-ink-faint">Remove</span>
                  <span className="font-mono font-semibold text-ink" data-testid="lp-remove-pct">
                    {removePct}%
                  </span>
                </div>
                <input
                  type="range"
                  className="cosmic-range mt-2"
                  min={1}
                  max={100}
                  value={removePct}
                  onChange={(e) => setRemovePct(Number(e.target.value))}
                  aria-label="Share of your liquidity to remove"
                  data-testid="lp-remove-slider"
                />
                {removePreview && (
                  <dl className="mt-3 space-y-1.5 text-xs">
                    <div className="flex justify-between">
                      <dt className="text-ink-faint">You receive</dt>
                      <dd className="font-mono text-ink" data-testid="lp-remove-preview">
                        {formatCst(removePreview.yesOut)} YES + {formatCst(removePreview.noOut)} NO
                      </dd>
                    </div>
                    <div className="flex justify-between">
                      <dt className="text-ink-faint">Plus accrued fees</dt>
                      <dd className="font-mono text-higher">{formatCst(position.pendingFees)} CST</dd>
                    </div>
                  </dl>
                )}
              </div>
              <Button
                className="mt-4 w-full"
                size="lg"
                variant="outline"
                loading={pendingAction === "removeLiquidity"}
                onClick={() => void submitRemove()}
                data-testid="lp-remove-submit"
              >
                Remove liquidity
              </Button>
              <p className="mt-3 text-center text-[11px] leading-relaxed text-ink-faint">
                Withdrawals work at ANY time — even mid-round or after resolution. Paired YES+NO tokens redeem 1:1
                for CST; the unpaired rest is your market exposure.
              </p>
            </>
          )}
        </>
      )}
    </Card>
  );
}

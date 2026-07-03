"use client";

import { useQueryClient } from "@tanstack/react-query";
import { useCallback, useState } from "react";
import { toast } from "sonner";
import type { Address, Hash } from "viem";
import { useConfig, useWriteContract } from "wagmi";
import { waitForTransactionReceipt } from "wagmi/actions";
import { erc20Abi } from "@/lib/abi/erc20";
import { gestureMarketAbi } from "@/lib/abi/gesture-market";
import { appConfig } from "@/lib/config";
import { describeTxError } from "@/lib/errors";
import type { BetSide } from "@/lib/math";

export type ActionKind = "approve" | "bet" | "mint" | "redeem" | "resolve" | "claim";

export interface MarketActions {
  /** Which action is currently mid-flight, if any (drives button spinners). */
  readonly pending: ActionKind | null;
  approve(cst: Address, amount: bigint): Promise<boolean>;
  bet(side: BetSide, cstIn: bigint, minTokensOut: bigint): Promise<boolean>;
  mintSets(amount: bigint): Promise<boolean>;
  redeemSets(amount: bigint): Promise<boolean>;
  resolve(): Promise<boolean>;
  claim(): Promise<boolean>;
}

function explorerTxUrl(hash: Hash): string | null {
  const base = appConfig.chain.blockExplorers?.default?.url;
  return base ? `${base.replace(/\/$/, "")}/tx/${hash}` : null;
}

/**
 * All writes to the market, wrapped in a uniform submit → confirm → refresh
 * flow with toast feedback. Every method resolves `true` on confirmed success.
 */
export function useMarketActions(market: Address | null): MarketActions {
  const config = useConfig();
  const queryClient = useQueryClient();
  const { writeContractAsync } = useWriteContract();
  const [pending, setPending] = useState<ActionKind | null>(null);

  const run = useCallback(
    async (kind: ActionKind, label: string, write: () => Promise<Hash>): Promise<boolean> => {
      if (pending) return false;
      setPending(kind);
      const toastId = toast.loading(`${label} — confirm in your wallet…`);
      try {
        const hash = await write();
        const url = explorerTxUrl(hash);
        toast.loading(`${label} — waiting for confirmation…`, {
          id: toastId,
          ...(url ? { action: { label: "View", onClick: () => window.open(url, "_blank") } } : {}),
        });
        const receipt = await waitForTransactionReceipt(config, { hash });
        if (receipt.status !== "success") {
          toast.error(`${label} failed on-chain.`, { id: toastId });
          return false;
        }
        toast.success(`${label} confirmed.`, {
          id: toastId,
          ...(url ? { action: { label: "View", onClick: () => window.open(url, "_blank") } } : {}),
        });
        return true;
      } catch (error) {
        toast.error(describeTxError(error), { id: toastId });
        return false;
      } finally {
        setPending(null);
        // Refresh everything that could have changed: reads and event history.
        void queryClient.invalidateQueries();
      }
    },
    [config, pending, queryClient],
  );

  const approve = useCallback(
    (cst: Address, amount: bigint) =>
      run("approve", "Approving CST", () =>
        writeContractAsync({
          address: cst,
          abi: erc20Abi,
          functionName: "approve",
          args: [market as Address, amount],
        }),
      ),
    [run, writeContractAsync, market],
  );

  const bet = useCallback(
    (side: BetSide, cstIn: bigint, minTokensOut: bigint) =>
      run("bet", side === "higher" ? "Betting HIGHER" : "Betting LOWER", () =>
        writeContractAsync({
          address: market as Address,
          abi: gestureMarketAbi,
          functionName: side === "higher" ? "betHigher" : "betLower",
          args: [cstIn, minTokensOut],
        }),
      ),
    [run, writeContractAsync, market],
  );

  const mintSets = useCallback(
    (amount: bigint) =>
      run("mint", "Minting sets", () =>
        writeContractAsync({
          address: market as Address,
          abi: gestureMarketAbi,
          functionName: "mintSets",
          args: [amount],
        }),
      ),
    [run, writeContractAsync, market],
  );

  const redeemSets = useCallback(
    (amount: bigint) =>
      run("redeem", "Redeeming sets", () =>
        writeContractAsync({
          address: market as Address,
          abi: gestureMarketAbi,
          functionName: "redeemSets",
          args: [amount],
        }),
      ),
    [run, writeContractAsync, market],
  );

  const resolve = useCallback(
    () =>
      run("resolve", "Resolving market", () =>
        writeContractAsync({
          address: market as Address,
          abi: gestureMarketAbi,
          functionName: "resolve",
        }),
      ),
    [run, writeContractAsync, market],
  );

  const claim = useCallback(
    () =>
      run("claim", "Claiming winnings", () =>
        writeContractAsync({
          address: market as Address,
          abi: gestureMarketAbi,
          functionName: "claim",
        }),
      ),
    [run, writeContractAsync, market],
  );

  return { pending, approve, bet, mintSets, redeemSets, resolve, claim };
}

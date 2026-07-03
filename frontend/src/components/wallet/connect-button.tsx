"use client";

import { ChevronDown, LogOut, TriangleAlert, Wallet } from "lucide-react";
import { useState } from "react";
import { useChainId, useConnection, useDisconnect, useSwitchChain } from "wagmi";
import { useMounted } from "@/hooks/use-mounted";
import { appConfig } from "@/lib/config";
import { shortAddress } from "@/lib/format";
import { Button } from "@/components/ui/button";
import { WalletModal } from "./wallet-modal";

/**
 * The single wallet entry point: connect → wrong-network warning → connected
 * menu with disconnect. Renders a stable placeholder before hydration.
 */
export function ConnectButton() {
  const mounted = useMounted();
  const connection = useConnection();
  const chainId = useChainId();
  const switchChain = useSwitchChain();
  const disconnect = useDisconnect();
  const [modalOpen, setModalOpen] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);

  if (!mounted) {
    return (
      <Button variant="outline" disabled>
        <Wallet className="size-4" aria-hidden />
        Connect
      </Button>
    );
  }

  if (connection.status !== "connected") {
    return (
      <>
        <Button variant="nova" onClick={() => setModalOpen(true)} loading={connection.status === "reconnecting"}>
          <Wallet className="size-4" aria-hidden />
          Connect wallet
        </Button>
        <WalletModal open={modalOpen} onClose={() => setModalOpen(false)} />
      </>
    );
  }

  if (chainId !== appConfig.chain.id) {
    return (
      <Button
        variant="ended"
        onClick={() => switchChain.mutate({ chainId: appConfig.chain.id })}
        loading={switchChain.isPending}
      >
        <TriangleAlert className="size-4" aria-hidden />
        Switch to {appConfig.chain.name}
      </Button>
    );
  }

  return (
    <div className="relative">
      <Button variant="outline" onClick={() => setMenuOpen((v) => !v)} aria-expanded={menuOpen}>
        <span className="size-2 rounded-full bg-higher shadow-glow-higher" aria-hidden />
        <span className="font-mono text-xs">{shortAddress(connection.address ?? "")}</span>
        <ChevronDown className="size-3.5 text-ink-dim" aria-hidden />
      </Button>
      {menuOpen && (
        <>
          <div className="fixed inset-0 z-30" onClick={() => setMenuOpen(false)} aria-hidden />
          <div className="absolute right-0 z-40 mt-2 w-44 overflow-hidden rounded-xl border border-line bg-surface shadow-[0_16px_48px_rgba(2,0,16,0.7)]">
            <button
              className="flex w-full items-center gap-2 px-4 py-3 text-left text-sm text-ink-dim transition-colors hover:bg-surface-2 hover:text-ink"
              onClick={() => {
                disconnect.mutate({});
                setMenuOpen(false);
              }}
            >
              <LogOut className="size-4" aria-hidden />
              Disconnect
            </button>
          </div>
        </>
      )}
    </div>
  );
}

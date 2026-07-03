"use client";

import { Orbit } from "lucide-react";
import Link from "next/link";
import { ConnectButton } from "@/components/wallet/connect-button";

export function Header() {
  return (
    <header className="sticky top-0 z-20 border-b border-line bg-space/70 backdrop-blur-lg">
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4 sm:px-6">
        <Link href="/" className="group flex items-center gap-2.5">
          <span className="flex size-9 items-center justify-center rounded-xl bg-nova/15 text-nova-bright transition-shadow group-hover:shadow-glow-nova">
            <Orbit className="size-5" aria-hidden />
          </span>
          <span className="font-display text-lg font-bold tracking-tight">
            Gesture<span className="text-nova-bright">Market</span>
          </span>
        </Link>
        <div className="flex items-center gap-3">
          <a
            href="https://cosmicsignature.com"
            target="_blank"
            rel="noopener noreferrer"
            className="hidden text-xs text-ink-faint transition-colors hover:text-nova-bright sm:block"
          >
            Play Cosmic Signature ↗
          </a>
          <ConnectButton />
        </div>
      </div>
    </header>
  );
}

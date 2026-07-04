"use client";

import { Orbit } from "lucide-react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { Badge } from "@/components/ui/badge";
import { ConnectButton } from "@/components/wallet/connect-button";

const NAV_LINKS = [
  { href: "/", label: "Market", isActive: (pathname: string) => pathname === "/" },
  { href: "/faq", label: "FAQ", isActive: (pathname: string) => pathname.startsWith("/faq") },
] as const;

export function Header() {
  const pathname = usePathname();

  return (
    <header className="sticky top-0 z-20 border-b border-line bg-space/70 backdrop-blur-lg">
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between gap-3 px-4 sm:px-6">
        <div className="flex min-w-0 items-center gap-3 sm:gap-6">
          <div className="flex items-center gap-2.5">
            <Link href="/" className="group flex items-center gap-2.5">
              <span className="flex size-9 shrink-0 items-center justify-center rounded-xl bg-nova/15 text-nova-bright transition-shadow group-hover:shadow-glow-nova">
                <Orbit className="size-5" aria-hidden />
              </span>
              <span className="hidden font-display text-lg font-bold tracking-tight md:block">
                Gesture<span className="text-nova-bright">Market</span>
              </span>
            </Link>
            <Badge tone="nova" pulse data-testid="beta-badge">
              Beta
            </Badge>
          </div>
          <nav aria-label="Primary" className="flex items-center gap-1">
            {NAV_LINKS.map((link) => {
              const active = link.isActive(pathname);
              return (
                <Link
                  key={link.href}
                  href={link.href}
                  aria-current={active ? "page" : undefined}
                  className={[
                    "rounded-lg px-2.5 py-1.5 text-sm font-medium transition-colors sm:px-3",
                    active ? "bg-nova/15 text-nova-bright" : "text-ink-dim hover:bg-surface-2 hover:text-ink",
                  ].join(" ")}
                >
                  {link.label}
                </Link>
              );
            })}
          </nav>
        </div>
        <div className="flex shrink-0 items-center gap-3">
          <a
            href="https://cosmicsignature.com"
            target="_blank"
            rel="noopener noreferrer"
            className="hidden text-xs text-ink-faint transition-colors hover:text-nova-bright lg:block"
          >
            Play Cosmic Signature ↗
          </a>
          <ConnectButton />
        </div>
      </div>
    </header>
  );
}

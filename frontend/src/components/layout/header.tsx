import { Orbit } from "lucide-react";
import Link from "next/link";
import type { ReactNode } from "react";
import { COSMIC_SIGNATURE_URL } from "@/lib/site";
import { Badge } from "@/components/ui/badge";
import { Tooltip } from "@/components/ui/tooltip";

const NAV_LINKS = [
  { id: "market", href: "/", label: "Market" },
  { id: "faq", href: "/faq", label: "FAQ" },
] as const;

export type NavPage = (typeof NAV_LINKS)[number]["id"];

interface HeaderProps {
  /** Which nav entry the current page is (drives aria-current + highlight). */
  active: NavPage;
  /**
   * Right-side slot: the wallet button on the market page, a plain CTA on
   * static pages. Keeping this a slot lets static pages ship without any
   * wallet JavaScript.
   */
  actions?: ReactNode;
}

/** Server-rendered site header; each page declares its own active tab and actions. */
export function Header({ active, actions }: HeaderProps) {
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
            <Tooltip
              side="bottom"
              align="start"
              content="Early software on a live chain: the contract is immutable and tested, but young. Size your bets accordingly."
            >
              <Badge tone="nova" pulse className="cursor-help" data-testid="beta-badge">
                Beta
              </Badge>
            </Tooltip>
          </div>
          <nav aria-label="Primary" className="flex items-center gap-1">
            {NAV_LINKS.map((link) => {
              const isActive = link.id === active;
              return (
                <Link
                  key={link.href}
                  href={link.href}
                  aria-current={isActive ? "page" : undefined}
                  className={[
                    "rounded-lg px-2.5 py-1.5 text-sm font-medium transition-colors sm:px-3",
                    isActive ? "bg-nova/15 text-nova-bright" : "text-ink-dim hover:bg-surface-2 hover:text-ink",
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
            href={COSMIC_SIGNATURE_URL}
            target="_blank"
            rel="noopener noreferrer"
            className="hidden text-xs text-ink-faint transition-colors hover:text-nova-bright lg:block"
          >
            Play Cosmic Signature ↗
          </a>
          {actions}
        </div>
      </div>
    </header>
  );
}

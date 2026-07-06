/**
 * The Chaos Zero mark: a slashed zero. The ring is the zero; the slash cuts
 * through it and its axis escapes into the market's two outcomes — the YES
 * satellite (green) up-right, the NO satellite (rose) down-left.
 *
 * Inline SVG so the header ships no extra request. The ring and slash take
 * `currentColor`, so the parent's text color drives the brand tint. The same
 * geometry is rasterized into every favicon by `scripts/generate-icons.mjs` —
 * keep the two in sync.
 */
export function BrandMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden fill="none">
      <circle cx="12" cy="12" r="8" stroke="currentColor" strokeWidth="2.5" />
      <path d="M14.8 8.5 9.2 15.5" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" />
      <circle cx="18.9" cy="3.4" r="2.2" fill="var(--color-higher)" />
      <circle cx="5.1" cy="20.6" r="2.2" fill="var(--color-lower)" />
    </svg>
  );
}

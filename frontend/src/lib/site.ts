/**
 * Canonical site identity: the single source of truth for the absolute site
 * URL, names, and descriptions used across metadata, Open Graph cards,
 * JSON-LD, the sitemap, robots.txt, and the web app manifest.
 *
 * `NEXT_PUBLIC_SITE_URL` overrides the production default so preview
 * deployments emit self-consistent absolute URLs.
 */

export const SITE_NAME = "Gesture Market";

/** The homepage <title> and social card headline. */
export const SITE_TITLE = "Gesture Market — bet on Cosmic Signature gestures";

/** One-line pitch for social cards and the manifest. */
export const SITE_TAGLINE = "Bet YES or NO on every Cosmic Signature round";

export const SITE_DESCRIPTION =
  "Will this Cosmic Signature round end with more gestures (bids) than the last one? " +
  "Bet YES or NO in CST on a fully collateralized, trustless prediction market on Arbitrum One — " +
  "one immutable contract, no oracles, no admin keys.";

export const SITE_KEYWORDS = [
  "Cosmic Signature",
  "prediction market",
  "gesture market",
  "CST token",
  "Arbitrum One",
  "on-chain betting",
  "crypto prediction market",
  "NFT game",
  "binary market",
] as const;

/** The Cosmic Signature game site this market is built on. */
export const COSMIC_SIGNATURE_URL = "https://cosmicsignature.com";

const DEFAULT_SITE_URL = "https://cosmicsignature.bet";

/**
 * Parses and normalizes the site origin. Absent input falls back to the
 * production domain; present-but-malformed input throws at startup rather
 * than silently emitting broken canonical URLs everywhere.
 */
export function parseSiteUrl(raw: string | undefined): string {
  const trimmed = raw?.trim();
  if (!trimmed) return DEFAULT_SITE_URL;
  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    throw new Error(`NEXT_PUBLIC_SITE_URL is not a valid URL: "${trimmed}"`);
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new Error(`NEXT_PUBLIC_SITE_URL must be http(s), got "${trimmed}"`);
  }
  return url.origin;
}

/** The site origin, without a trailing slash (e.g. "https://cosmicsignature.bet"). */
export const SITE_URL = parseSiteUrl(process.env.NEXT_PUBLIC_SITE_URL);

/** Turns a site-relative path into an absolute URL for sitemaps and JSON-LD. */
export function absoluteUrl(path: string, base: string = SITE_URL): string {
  if (!path.startsWith("/")) {
    throw new Error(`absoluteUrl expects a site-relative path starting with "/", got "${path}"`);
  }
  return path === "/" ? base : `${base}${path}`;
}

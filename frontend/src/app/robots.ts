import type { MetadataRoute } from "next";
import { absoluteUrl } from "@/lib/site";

/**
 * AI crawlers welcomed by name. `*` already allows everyone, but naming the
 * agents makes the policy explicit and survives any future `*` tightening —
 * being quotable by assistants and answer engines is part of this site's
 * distribution. Exported for the SEO tests.
 */
export const AI_CRAWLERS = [
  "GPTBot",
  "OAI-SearchBot",
  "ChatGPT-User",
  "ClaudeBot",
  "Claude-Web",
  "anthropic-ai",
  "PerplexityBot",
  "Google-Extended",
  "Applebot-Extended",
  "CCBot",
  "meta-externalagent",
] as const;

/** Everything is public; point every crawler (human-web and AI) at the site. */
export default function robots(): MetadataRoute.Robots {
  return {
    rules: [
      {
        userAgent: "*",
        allow: "/",
      },
      {
        userAgent: [...AI_CRAWLERS],
        allow: "/",
      },
    ],
    sitemap: absoluteUrl("/sitemap.xml"),
  };
}

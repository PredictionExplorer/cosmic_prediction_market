/**
 * Schema.org JSON-LD builders. Structured data is how search engines and AI
 * crawlers understand the site beyond its visible text: the homepage
 * describes the site and the app, and the FAQ page publishes every question
 * and answer machine-readably even before any JavaScript runs.
 */

import {
  COSMIC_SIGNATURE_URL,
  SITE_DESCRIPTION,
  SITE_NAME,
  SITE_URL,
  absoluteUrl,
} from "./site";

export type JsonLd = Record<string, unknown>;

/**
 * Serializes JSON-LD for embedding in a <script> tag. `<` is escaped so no
 * string in the payload can ever open an HTML tag (XSS via `</script>`).
 */
export function serializeJsonLd(data: JsonLd): string {
  return JSON.stringify(data).replace(/</g, "\\u003c");
}

/** The site itself: who we are and where we live. */
export function webSiteJsonLd(): JsonLd {
  return {
    "@context": "https://schema.org",
    "@type": "WebSite",
    name: SITE_NAME,
    alternateName: "GestureMarket",
    url: SITE_URL,
    description: SITE_DESCRIPTION,
  };
}

/** The dapp: a free-to-use finance web application about the Cosmic Signature game. */
export function webApplicationJsonLd(): JsonLd {
  return {
    "@context": "https://schema.org",
    "@type": "WebApplication",
    name: SITE_NAME,
    url: SITE_URL,
    description: SITE_DESCRIPTION,
    applicationCategory: "FinanceApplication",
    operatingSystem: "Any",
    browserRequirements: "Requires JavaScript. A Web3 wallet is needed to place bets.",
    offers: {
      "@type": "Offer",
      price: "0",
      priceCurrency: "USD",
    },
    about: {
      "@type": "VideoGame",
      name: "Cosmic Signature",
      url: COSMIC_SIGNATURE_URL,
    },
  };
}

export interface FaqEntry {
  readonly question: string;
  /** One entry per paragraph. */
  readonly answer: readonly string[];
}

/** The whole FAQ as a schema.org FAQPage, one Question per item. */
export function faqPageJsonLd(items: readonly FaqEntry[]): JsonLd {
  return {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    url: absoluteUrl("/faq"),
    mainEntity: items.map((item) => ({
      "@type": "Question",
      name: item.question,
      acceptedAnswer: {
        "@type": "Answer",
        text: item.answer.join("\n\n"),
      },
    })),
  };
}

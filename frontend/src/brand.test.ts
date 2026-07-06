import { readdirSync, readFileSync } from "node:fs";
import { basename, join, relative } from "node:path";
import { describe, expect, it } from "vitest";
import { SITE_NAME, SITE_URL } from "@/lib/site";

/**
 * Brand guard: the site is Chaos Zero (chaoszero.com). This test sweeps every
 * source file so no pre-rebrand string — the old "Gesture Market" name, the
 * old cosmicsignature.bet domain, or a dead theme token — can sneak back in
 * through a stale copy-paste.
 *
 * Deliberately allowed: `GestureSeriesMarket` (and its ABI file). That is the
 * name of the deployed, verified on-chain contract — an immutable technical
 * identifier, not branding.
 */

const FRONTEND_ROOT = process.cwd();
const SCAN_EXTENSIONS = [".ts", ".tsx", ".css", ".mjs"];

const FORBIDDEN: readonly { pattern: RegExp; why: string }[] = [
  // matches "Gesture Market", "gesture market", "GestureMarket", "gesture-market"
  // but not the contract name "GestureSeriesMarket".
  { pattern: /gesture[\s-]?market/i, why: "old brand name" },
  { pattern: /cosmicsignature\.bet/i, why: "old production domain" },
  { pattern: /-nova/, why: "removed theme token (nova → signal)" },
  { pattern: /"nova"/, why: "removed tone/variant name (nova → signal)" },
  { pattern: /\bnova:/, why: "removed tone/variant key (nova → signal)" },
  { pattern: /--color-space/, why: "removed theme token (space → void)" },
  { pattern: /\b(?:bg|text|border)-space\b/, why: "removed color class (space → void)" },
  { pattern: /cosmic-range/, why: "renamed utility class (cosmic-range → chaos-range)" },
];

/** Every scannable source file under `dir`, recursively. */
function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return sourceFiles(path);
    return SCAN_EXTENSIONS.some((ext) => entry.name.endsWith(ext)) ? [path] : [];
  });
}

// This file spells out the forbidden patterns, so it exempts itself.
const files = [
  ...sourceFiles(join(FRONTEND_ROOT, "src")).filter((file) => basename(file) !== "brand.test.ts"),
  ...sourceFiles(join(FRONTEND_ROOT, "scripts")),
  join(FRONTEND_ROOT, "public", "llms.txt"),
  join(FRONTEND_ROOT, "package.json"),
  join(FRONTEND_ROOT, ".env.example"),
  join(FRONTEND_ROOT, "README.md"),
  join(FRONTEND_ROOT, "..", "README.md"),
];

describe("brand consistency", () => {
  it("declares the Chaos Zero identity", () => {
    expect(SITE_NAME).toBe("Chaos Zero");
    expect(new URL(SITE_URL).host).toBe("chaoszero.com");
  });

  it("carries no pre-rebrand leftovers anywhere in the source tree", () => {
    const violations: string[] = [];
    for (const file of files) {
      const text = readFileSync(file, "utf8");
      for (const { pattern, why } of FORBIDDEN) {
        const match = text.match(pattern);
        if (match) {
          violations.push(`${relative(FRONTEND_ROOT, file)}: "${match[0]}" (${why})`);
        }
      }
    }
    expect(violations, violations.join("\n")).toEqual([]);
  });

  it("ships favicons in the rebranded palette", () => {
    const iconSvg = readFileSync(join(FRONTEND_ROOT, "src", "app", "icon.svg"), "utf8");
    // The signal-cyan arc from globals.css; fails if icons weren't regenerated.
    expect(iconSvg).toContain("#67e8f9");
    expect(iconSvg).not.toContain("#a89bff");
  });
});

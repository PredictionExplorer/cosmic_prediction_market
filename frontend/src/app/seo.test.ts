import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { SITE_URL } from "@/lib/site";
import manifest from "./manifest";
import robots from "./robots";
import sitemap from "./sitemap";

const PUBLIC_DIR = join(process.cwd(), "public");

describe("robots.txt", () => {
  const data = robots();

  it("allows every crawler everywhere (the whole site is public)", () => {
    expect(data.rules).toEqual([{ userAgent: "*", allow: "/" }]);
  });

  it("points crawlers at the sitemap with an absolute URL", () => {
    expect(data.sitemap).toBe(`${SITE_URL}/sitemap.xml`);
  });
});

describe("sitemap.xml", () => {
  const entries = sitemap();

  it("lists exactly the two routes with absolute URLs", () => {
    expect(entries.map((e) => e.url)).toEqual([SITE_URL, `${SITE_URL}/faq`]);
    for (const entry of entries) {
      expect(entry.url).toMatch(/^https?:\/\//);
      expect(entry.lastModified).toBeInstanceOf(Date);
    }
  });

  it("ranks the live market above the FAQ", () => {
    const [home, faq] = entries;
    expect(home!.priority).toBe(1);
    expect(faq!.priority).toBeLessThan(1);
  });
});

describe("manifest", () => {
  const data = manifest();

  it("matches the void theme", () => {
    expect(data.theme_color).toBe("#060a10");
    expect(data.background_color).toBe("#060a10");
    expect(data.display).toBe("standalone");
  });

  it("references only icons that actually exist in public/", () => {
    expect(data.icons?.length).toBeGreaterThanOrEqual(3);
    for (const icon of data.icons ?? []) {
      expect(icon.src.startsWith("/")).toBe(true);
      expect(existsSync(join(PUBLIC_DIR, icon.src)), `${icon.src} missing — run \`pnpm icons\``).toBe(true);
    }
  });

  it("includes a maskable icon for Android launchers", () => {
    expect(data.icons?.some((icon) => icon.purpose === "maskable")).toBe(true);
  });
});

describe("llms.txt", () => {
  const path = join(PUBLIC_DIR, "llms.txt");

  it("exists and explains the market to AI crawlers", () => {
    expect(existsSync(path)).toBe(true);
    const text = readFileSync(path, "utf8");
    expect(text).toMatch(/^# Chaos Zero/);
    expect(text).toMatch(/cosmic signature/i);
    expect(text).toMatch(/gestures? \(bids\)/i);
    expect(text).toMatch(/YES/);
    expect(text).toContain(SITE_URL);
    expect(text).toContain("https://cosmicsignature.com");
  });
});

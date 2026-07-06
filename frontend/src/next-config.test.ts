import { describe, expect, it } from "vitest";
import nextConfig, { DOMAIN_REDIRECTS } from "../next.config";

/**
 * The domain migration lives or dies on these rules: the old domain's link
 * equity only transfers if every legacy host 308s to chaoszero.com with the
 * path preserved.
 */
describe("domain redirects", () => {
  it("covers the pre-rebrand domain (bare + www) and the www variant of the new domain", () => {
    const hosts = DOMAIN_REDIRECTS.map((rule) => rule.has?.[0]?.value);
    expect(hosts).toEqual(["cosmicsignature.bet", "www.cosmicsignature.bet", "www.chaoszero.com"]);
  });

  it("redirects permanently to the canonical origin with the path intact", () => {
    for (const rule of DOMAIN_REDIRECTS) {
      expect(rule).toMatchObject({
        source: "/:path*",
        destination: "https://chaoszero.com/:path*",
        permanent: true,
      });
      expect(rule.has).toHaveLength(1);
      expect(rule.has?.[0]?.type).toBe("host");
    }
  });

  it("is wired into the Next config", async () => {
    expect(await nextConfig.redirects?.()).toEqual(DOMAIN_REDIRECTS);
  });
});

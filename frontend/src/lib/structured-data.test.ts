import { describe, expect, it } from "vitest";
import { FAQ_CATEGORIES } from "@/components/faq/faq-data";
import { SITE_URL } from "./site";
import { faqPageJsonLd, serializeJsonLd, webApplicationJsonLd, webSiteJsonLd } from "./structured-data";

describe("serializeJsonLd", () => {
  it("escapes < so no payload string can ever close the script tag", () => {
    const out = serializeJsonLd({ name: '</script><script>alert("xss")</script>' });
    expect(out).not.toContain("<");
    expect(out).toContain("\\u003c/script");
  });

  it("round-trips through JSON.parse unchanged", () => {
    const data = { "@type": "Thing", name: "a < b", nested: { items: [1, "two"] } };
    expect(JSON.parse(serializeJsonLd(data))).toEqual(data);
  });
});

describe("webSiteJsonLd", () => {
  it("declares the site with an absolute URL", () => {
    const data = webSiteJsonLd();
    expect(data["@context"]).toBe("https://schema.org");
    expect(data["@type"]).toBe("WebSite");
    expect(data.url).toBe(SITE_URL);
    expect(String(data.url)).toMatch(/^https?:\/\//);
  });
});

describe("webApplicationJsonLd", () => {
  it("describes a free finance app about the Cosmic Signature game", () => {
    const data = webApplicationJsonLd();
    expect(data["@type"]).toBe("WebApplication");
    expect(data.applicationCategory).toBe("FinanceApplication");
    expect(data.offers).toMatchObject({ "@type": "Offer", price: "0" });
    expect(data.about).toMatchObject({ name: "Cosmic Signature", url: "https://cosmicsignature.com" });
  });
});

describe("faqPageJsonLd", () => {
  const allItems = FAQ_CATEGORIES.flatMap((category) => category.items);
  const data = faqPageJsonLd(allItems);
  const questions = data.mainEntity as Array<{
    "@type": string;
    name: string;
    acceptedAnswer: { "@type": string; text: string };
  }>;

  it("contains one Question per real FAQ item", () => {
    expect(data["@type"]).toBe("FAQPage");
    expect(questions).toHaveLength(allItems.length);
    expect(allItems.length).toBeGreaterThan(10);
  });

  it("carries every question and every answer paragraph verbatim", () => {
    for (const [i, item] of allItems.entries()) {
      const question = questions[i]!;
      expect(question["@type"]).toBe("Question");
      expect(question.name).toBe(item.question);
      expect(question.acceptedAnswer["@type"]).toBe("Answer");
      for (const paragraph of item.answer) {
        expect(question.acceptedAnswer.text).toContain(paragraph);
      }
    }
  });

  it("links to the FAQ page with an absolute URL", () => {
    expect(data.url).toBe(`${SITE_URL}/faq`);
  });

  it("serializes without unescaped angle brackets", () => {
    expect(serializeJsonLd(data)).not.toContain("<");
  });
});

import { describe, expect, it } from "vitest";
import {
  formatBps,
  formatCount,
  formatCountPrecise,
  formatCst,
  formatSignedCst,
  parseCstInput,
  shortAddress,
  timeAgo,
} from "./format";
import { ONE } from "./math";

describe("formatCst", () => {
  it("uses no decimals for large amounts", () => {
    expect(formatCst(12_345n * ONE)).toBe("12,345");
  });

  it("scales decimals with magnitude", () => {
    expect(formatCst(42n * ONE + ONE / 2n)).toBe("42.5");
    expect(formatCst(ONE + ONE / 4n)).toBe("1.25");
    expect(formatCst(ONE / 1000n)).toBe("0.001");
  });

  it("formats zero plainly", () => {
    expect(formatCst(0n)).toBe("0");
  });

  it("honours a decimals override", () => {
    expect(formatCst(1_234n * ONE + ONE / 2n, { decimals: 2 })).toBe("1,234.5");
  });
});

describe("formatCount / formatCountPrecise", () => {
  it("adds thousands separators", () => {
    expect(formatCount(1_234n)).toBe("1,234");
    expect(formatCount(987)).toBe("987");
  });

  it("rounds fractional inputs", () => {
    expect(formatCount(699.7)).toBe("700");
  });

  it("precise variant keeps exactly one decimal", () => {
    expect(formatCountPrecise(699.72)).toBe("699.7");
    expect(formatCountPrecise(700)).toBe("700.0");
  });
});

describe("shortAddress", () => {
  it("shortens long addresses", () => {
    expect(shortAddress("0x6a714Ae7B5b6eA520F6BCA23d2E609C4Fd5863F2")).toBe("0x6a71…63F2");
  });

  it("leaves short strings alone", () => {
    expect(shortAddress("0x1234")).toBe("0x1234");
  });
});

describe("formatSignedCst", () => {
  it("adds explicit signs", () => {
    expect(formatSignedCst(5n * ONE)).toBe("+5");
    expect(formatSignedCst(-5n * ONE)).toBe("−5");
    expect(formatSignedCst(0n)).toBe("0");
  });
});

describe("formatBps", () => {
  it("renders basis points as percent", () => {
    expect(formatBps(100n)).toBe("1%");
    expect(formatBps(25n)).toBe("0.25%");
    expect(formatBps(1_000n)).toBe("10%");
  });
});

describe("timeAgo", () => {
  const now = 1_700_000_000_000; // ms
  it("buckets into human units", () => {
    expect(timeAgo(now / 1000 - 2, now)).toBe("just now");
    expect(timeAgo(now / 1000 - 45, now)).toBe("45s ago");
    expect(timeAgo(now / 1000 - 300, now)).toBe("5m ago");
    expect(timeAgo(now / 1000 - 7_200, now)).toBe("2h ago");
    expect(timeAgo(now / 1000 - 200_000, now)).toBe("2d ago");
  });

  it("never returns negative durations for future timestamps", () => {
    expect(timeAgo(now / 1000 + 100, now)).toBe("just now");
  });
});

describe("parseCstInput", () => {
  it("parses plain and decimal amounts", () => {
    expect(parseCstInput("1").value).toBe(ONE);
    expect(parseCstInput("0.5").value).toBe(ONE / 2n);
    expect(parseCstInput(".5").value).toBe(ONE / 2n);
    expect(parseCstInput("1,000.25").value).toBe(1_000n * ONE + ONE / 4n);
  });

  it("treats empty input as no value, no error", () => {
    expect(parseCstInput("")).toEqual({ value: null, error: null });
    expect(parseCstInput("   ")).toEqual({ value: null, error: null });
  });

  it("rejects garbage", () => {
    for (const bad of ["abc", "1e18", "-5", "1.2.3", ".", "0x10"]) {
      const r = parseCstInput(bad);
      expect(r.value).toBeNull();
      expect(r.error).toBeTruthy();
    }
  });

  it("rejects zero", () => {
    const r = parseCstInput("0");
    expect(r.value).toBeNull();
    expect(r.error).toMatch(/more than 0/);
  });

  it("rejects more than 18 decimals", () => {
    const r = parseCstInput("0.1234567890123456789");
    expect(r.value).toBeNull();
    expect(r.error).toMatch(/decimal/);
  });

  it("accepts exactly 18 decimals", () => {
    expect(parseCstInput("0.123456789012345678").value).toBe(123456789012345678n);
  });
});

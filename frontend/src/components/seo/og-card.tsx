import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ImageResponse } from "next/og";
import { SITE_URL } from "@/lib/site";

/**
 * The social share card (Open Graph + Twitter), generated once at build time.
 * Shared by `app/opengraph-image.tsx` and `app/twitter-image.tsx` so both
 * networks get the identical, brand-correct image.
 */

export const OG_SIZE = { width: 1200, height: 630 };

export const OG_ALT =
  "Gesture Market — bet YES or NO on whether each Cosmic Signature round ends with more gestures than the last, in CST on Arbitrum One.";

// Palette from globals.css.
const SPACE = "#07060e";
const INK = "#f0edfa";
const INK_DIM = "#a49bc4";
const NOVA = "#8b7bff";
const NOVA_BRIGHT = "#a89bff";
const HIGHER = "#34e3a5";
const LOWER = "#ff6584";

// The lucide "orbit" glyph used by the header logo and favicons.
function OrbitGlyph({ size }: { size: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24">
      <g fill="none" stroke={NOVA_BRIGHT} strokeWidth={2.5} strokeLinecap="round">
        <path d="M20.341 6.484A10 10 0 0 1 10.266 21.85" />
        <path d="M3.659 17.516A10 10 0 0 1 13.74 2.152" />
      </g>
      <circle cx={12} cy={12} r={3.2} fill={NOVA_BRIGHT} />
      <circle cx={19} cy={5} r={2.4} fill={HIGHER} />
      <circle cx={5} cy={19} r={2.4} fill={LOWER} />
    </svg>
  );
}

function Pill({ color, children }: { color: string; children: string }) {
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        borderRadius: 18,
        border: `2px solid ${color}55`,
        backgroundColor: `${color}1f`,
        color,
        fontSize: 28,
        padding: "12px 28px",
      }}
    >
      {children}
    </div>
  );
}

export async function ogCardResponse(): Promise<ImageResponse> {
  // Vendored (SIL OFL 1.1) so the build never fetches fonts from the network.
  const spaceGrotesk = await readFile(join(process.cwd(), "src/assets/fonts/SpaceGrotesk-Bold.ttf"));

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          padding: 64,
          backgroundColor: SPACE,
          backgroundImage:
            `radial-gradient(720px 420px at 8% -12%, ${NOVA}3d, transparent 60%), ` +
            `radial-gradient(560px 360px at 96% 6%, ${HIGHER}1f, transparent 60%), ` +
            `radial-gradient(640px 440px at 55% 118%, ${LOWER}1c, transparent 62%)`,
          fontFamily: "Space Grotesk",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 20 }}>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              width: 84,
              height: 84,
              borderRadius: 24,
              backgroundColor: `${NOVA}26`,
            }}
          >
            <OrbitGlyph size={52} />
          </div>
          <div style={{ display: "flex", fontSize: 44, color: INK }}>
            <span>Gesture</span>
            <span style={{ color: NOVA_BRIGHT }}>Market</span>
          </div>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 22 }}>
          <div style={{ display: "flex", fontSize: 84, lineHeight: 1.04, color: INK, maxWidth: 1020 }}>
            Bet YES or NO on every Cosmic Signature round
          </div>
          <div style={{ display: "flex", fontSize: 32, lineHeight: 1.3, color: INK_DIM, maxWidth: 980 }}>
            Will this round end with more gestures than the last? Trustless, fully collateralized, settled in CST.
          </div>
        </div>

        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <div style={{ display: "flex", gap: 18 }}>
            <Pill color={HIGHER}>YES pays 1 CST</Pill>
            <Pill color={LOWER}>NO pays 1 CST</Pill>
          </div>
          <div style={{ display: "flex", fontSize: 30, color: INK_DIM }}>{new URL(SITE_URL).host}</div>
        </div>
      </div>
    ),
    {
      ...OG_SIZE,
      fonts: [{ name: "Space Grotesk", data: spaceGrotesk, weight: 700, style: "normal" }],
    },
  );
}

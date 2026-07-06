/**
 * Generates the app icon set from a single source of truth (the lucide
 * "orbit" glyph used in the site header) in the Gesture Market palette:
 *
 *   src/app/icon.svg              transparent SVG favicon, dark/light aware
 *   src/app/favicon.ico           legacy fallback, 16/32/48 RGBA PNG entries
 *   src/app/apple-icon.png        180x180 opaque touch icon
 *   public/icon-192.png           PWA/manifest tile
 *   public/icon-512.png           PWA/manifest tile
 *   public/icon-maskable-512.png  maskable tile (glyph inside the safe zone)
 *
 * Regenerate with: pnpm icons
 */
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const appDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "src", "app");
const publicDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "public");

// Geometry of lucide "orbit" (24x24 grid), as rendered by the header logo.
const ARC_A = "M20.341 6.484A10 10 0 0 1 10.266 21.85";
const ARC_B = "M3.659 17.516A10 10 0 0 1 13.74 2.152";

// Palette from globals.css. The satellites take the market's two sides:
// aurora green (HIGHER) top-right, nebula rose (LOWER) bottom-left.
const DARK = { arc: "#a89bff", higher: "#34e3a5", lower: "#ff6584" };
const LIGHT = { arc: "#6c56e8", higher: "#0ea975", lower: "#e14b6d" };
// Baked into the ICO fallback, which cannot adapt: mid tones that stay
// legible on both light and dark tab bars.
const UNIVERSAL = { arc: "#8b7bff", higher: "#29cf93", lower: "#f75c7e" };

/** Orbit glyph on the 24x24 grid with explicit colors (for rasterization). */
function glyph(colors, { stroke = 2.5, coreR = 3.2, satR = 2.4 } = {}) {
  return `
    <g fill="none" stroke="${colors.arc}" stroke-width="${stroke}" stroke-linecap="round">
      <path d="${ARC_A}"/>
      <path d="${ARC_B}"/>
    </g>
    <circle cx="12" cy="12" r="${coreR}" fill="${colors.arc}"/>
    <circle cx="19" cy="5" r="${satR}" fill="${colors.higher}"/>
    <circle cx="5" cy="19" r="${satR}" fill="${colors.lower}"/>`;
}

// --- icon.svg: transparent, adapts to the browser's color scheme ----------

const iconSvg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <style>
    .a { stroke: ${DARK.arc}; }
    .c { fill: ${DARK.arc}; }
    .h { fill: ${DARK.higher}; }
    .l { fill: ${DARK.lower}; }
    @media (prefers-color-scheme: light) {
      .a { stroke: ${LIGHT.arc}; }
      .c { fill: ${LIGHT.arc}; }
      .h { fill: ${LIGHT.higher}; }
      .l { fill: ${LIGHT.lower}; }
    }
  </style>
  <g fill="none" stroke-width="2.5" stroke-linecap="round">
    <path class="a" d="${ARC_A}"/>
    <path class="a" d="${ARC_B}"/>
  </g>
  <circle class="c" cx="12" cy="12" r="3.2"/>
  <circle class="h" cx="19" cy="5" r="2.4"/>
  <circle class="l" cx="5" cy="19" r="2.4"/>
</svg>
`;

// --- favicon.ico: 16/32/48 transparent PNGs in an ICO container ------------

async function renderPng(size, colors, tuning) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 24 24">${glyph(colors, tuning)}</svg>`;
  return sharp(Buffer.from(svg)).png().toBuffer();
}

/** Minimal ICO container: ICONDIR + ICONDIRENTRYs + PNG payloads. */
function buildIco(entries) {
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0); // reserved
  header.writeUInt16LE(1, 2); // type: icon
  header.writeUInt16LE(entries.length, 4);

  let offset = 6 + 16 * entries.length;
  const dirs = entries.map(({ size, png }) => {
    const dir = Buffer.alloc(16);
    dir.writeUInt8(size >= 256 ? 0 : size, 0); // width
    dir.writeUInt8(size >= 256 ? 0 : size, 1); // height
    dir.writeUInt8(0, 2); // no palette
    dir.writeUInt8(0, 3); // reserved
    dir.writeUInt16LE(1, 4); // color planes
    dir.writeUInt16LE(32, 6); // bits per pixel
    dir.writeUInt32LE(png.length, 8);
    dir.writeUInt32LE(offset, 12);
    offset += png.length;
    return dir;
  });

  return Buffer.concat([header, ...dirs, ...entries.map((e) => e.png)]);
}

// --- apple-icon.png: opaque deep-space tile (iOS composites black behind
// transparency, so an explicit background is the safe choice) ---------------

const appleSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="180" height="180" viewBox="0 0 180 180">
  <defs>
    <radialGradient id="glow" cx="30%" cy="16%" r="90%">
      <stop offset="0%" stop-color="#8b7bff" stop-opacity="0.30"/>
      <stop offset="55%" stop-color="#8b7bff" stop-opacity="0.07"/>
      <stop offset="100%" stop-color="#8b7bff" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="180" height="180" fill="#0c0a18"/>
  <rect width="180" height="180" fill="url(#glow)"/>
  <g transform="translate(90 90) scale(4.6) translate(-12 -12)">${glyph(DARK)}</g>
</svg>`;

// --- manifest icons: opaque deep-space tiles for PWA launchers ------------
// glyphScale is the fraction of the tile the 24px glyph grid spans; maskable
// icons keep the glyph inside the central safe zone (~80% circle).

function tileSvg(size, glyphScale) {
  const scale = (size * glyphScale) / 24;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
  <defs>
    <radialGradient id="glow" cx="30%" cy="16%" r="90%">
      <stop offset="0%" stop-color="#8b7bff" stop-opacity="0.30"/>
      <stop offset="55%" stop-color="#8b7bff" stop-opacity="0.07"/>
      <stop offset="100%" stop-color="#8b7bff" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="${size}" height="${size}" fill="#0c0a18"/>
  <rect width="${size}" height="${size}" fill="url(#glow)"/>
  <g transform="translate(${size / 2} ${size / 2}) scale(${scale}) translate(-12 -12)">${glyph(DARK)}</g>
</svg>`;
}

async function main() {
  await mkdir(appDir, { recursive: true });
  await mkdir(publicDir, { recursive: true });

  await writeFile(path.join(appDir, "icon.svg"), iconSvg);

  const icoEntries = await Promise.all(
    [
      // Slightly heavier strokes and larger dots at 16px for legibility.
      { size: 16, tuning: { stroke: 3, coreR: 3.4, satR: 2.6 } },
      { size: 32, tuning: {} },
      { size: 48, tuning: {} },
    ].map(async ({ size, tuning }) => ({
      size,
      png: await renderPng(size, UNIVERSAL, tuning),
    })),
  );
  await writeFile(path.join(appDir, "favicon.ico"), buildIco(icoEntries));

  const applePng = await sharp(Buffer.from(appleSvg)).png().toBuffer();
  await writeFile(path.join(appDir, "apple-icon.png"), applePng);

  const manifestIcons = [
    { file: "icon-192.png", size: 192, glyphScale: 0.62 },
    { file: "icon-512.png", size: 512, glyphScale: 0.62 },
    { file: "icon-maskable-512.png", size: 512, glyphScale: 0.44 },
  ];
  for (const { file, size, glyphScale } of manifestIcons) {
    const png = await sharp(Buffer.from(tileSvg(size, glyphScale))).png().toBuffer();
    await writeFile(path.join(publicDir, file), png);
  }

  console.log(
    "Wrote icon.svg, favicon.ico (16/32/48), apple-icon.png, icon-192/512.png, icon-maskable-512.png",
  );
}

await main();

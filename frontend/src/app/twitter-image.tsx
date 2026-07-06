import { OG_ALT, OG_SIZE, ogCardResponse } from "@/components/seo/og-card";

export const alt = OG_ALT;
export const size = OG_SIZE;
export const contentType = "image/png";

export default async function TwitterImage() {
  return ogCardResponse();
}

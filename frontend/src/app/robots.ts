import type { MetadataRoute } from "next";
import { absoluteUrl } from "@/lib/site";

/** Everything is public; point every crawler at the sitemap. */
export default function robots(): MetadataRoute.Robots {
  return {
    rules: [
      {
        userAgent: "*",
        allow: "/",
      },
    ],
    sitemap: absoluteUrl("/sitemap.xml"),
  };
}

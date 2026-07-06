import { llmsFullTxt } from "@/lib/llms";

/** Rendered once at build time, like the sitemap. */
export const dynamic = "force-static";

export function GET(): Response {
  return new Response(llmsFullTxt(), {
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}

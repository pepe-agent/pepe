import type { APIRoute } from "astro";
import { buildLlmsFullTxt } from "../docs/llms";

// The llms.txt spec's "full" companion (see https://llmstxt.org): every doc
// page's actual content in one file, English. Localized at
// /en|es|pt-br|pt-pt/llms-full.txt.
export const GET: APIRoute = () => {
  return new Response(buildLlmsFullTxt("en"), {
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "public, max-age=300",
    },
  });
};

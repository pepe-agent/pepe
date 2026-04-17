import type { APIRoute } from "astro";
import { buildLlmsTxt } from "../docs/llms";

// Canonical /llms.txt (see https://llmstxt.org) - the root, language-neutral
// entry point most crawlers look for. Content is the English docs; localized
// versions live at /en/llms.txt, /es/llms.txt, /pt-br/llms.txt, /pt-pt/llms.txt.
export const GET: APIRoute = () => {
  return new Response(buildLlmsTxt("en"), {
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "public, max-age=300",
    },
  });
};

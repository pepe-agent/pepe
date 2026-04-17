import type { APIRoute } from "astro";
import { locales, type Locale } from "../../i18n/ui";
import { buildLlmsFullTxt } from "../../docs/llms";

// Localized llms-full.txt per https://llmstxt.org - same content as the root
// /llms-full.txt, just in each site language.
export function getStaticPaths() {
  return locales.map((lang) => ({ params: { lang } }));
}

export const GET: APIRoute = ({ params }) => {
  const lang = params.lang as Locale;

  return new Response(buildLlmsFullTxt(lang), {
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "public, max-age=300",
    },
  });
};

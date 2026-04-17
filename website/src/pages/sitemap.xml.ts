import type { APIRoute } from "astro";
import { execFileSync } from "node:child_process";
import { locales } from "../i18n/ui";
import { allSlugs } from "../docs/nav";

const SITE = "https://pepe-agent.com";

// Every path this site serves, per locale, paired with the source file whose
// git history gives it an honest <lastmod> - never a fabricated "now".
const staticPaths: { path: string; source: string }[] = [
  { path: "", source: "src/pages/[lang]/index.astro" },
  { path: "privacy/", source: "src/pages/[lang]/privacy.astro" },
  { path: "terms/", source: "src/pages/[lang]/terms.astro" },
];

const docPaths = allSlugs.map((slug) => ({
  path: slug === "index" ? "docs/" : `docs/${slug}/`,
  slug,
}));

function urlFor(lang: string, path: string) {
  return `${SITE}/${lang}/${path}`;
}

// A doc's source file is locale-specific (a page not yet translated falls
// back to the English file - see llms.ts/search.json.ts's same rule - so its
// lastmod is honestly the English version's, not a made-up date).
function docSource(lang: string, slug: string) {
  const own = `src/docs/${lang}/${slug}.md`;
  return existsAsGitFile(own) ? own : `src/docs/en/${slug}.md`;
}

const lastmodCache = new Map<string, string | null>();
const gitFileCache = new Map<string, boolean>();

function existsAsGitFile(relPath: string) {
  if (gitFileCache.has(relPath)) return gitFileCache.get(relPath)!;

  let exists = false;
  try {
    execFileSync("git", ["cat-file", "-e", `HEAD:${relPath}`], { stdio: "pipe" });
    exists = true;
  } catch {
    exists = false;
  }

  gitFileCache.set(relPath, exists);
  return exists;
}

// Last commit date that touched this file, as a date-only ISO string
// (sitemaps only need day-level granularity). `null` when git history isn't
// available (a shallow checkout, no repo) - the entry just omits <lastmod>
// rather than guessing.
function lastmodFor(relPath: string): string | null {
  if (lastmodCache.has(relPath)) return lastmodCache.get(relPath)!;

  let date: string | null = null;
  try {
    const out = execFileSync("git", ["log", "-1", "--format=%aI", "--", relPath], { stdio: "pipe" })
      .toString()
      .trim();
    if (out) date = out.slice(0, 10);
  } catch {
    date = null;
  }

  lastmodCache.set(relPath, date);
  return date;
}

// Per Google's multilingual-sitemap guidance: every language version gets its
// OWN <url> entry (loc = that version's real URL), and every entry in the
// group carries the SAME full set of <xhtml:link> alternates (including one
// pointing at itself) - not one shared entry per path. That's the hreflang
// signal already in each page's <head>, mirrored here as a second, crawlable
// source instead of relying on discovery alone.
function alternateLinks(path: string) {
  const links = locales.map(
    (locale) => `    <xhtml:link rel="alternate" hreflang="${locale}" href="${urlFor(locale, path)}"/>`,
  );
  links.push(`    <xhtml:link rel="alternate" hreflang="x-default" href="${urlFor("en", path)}"/>`);
  return links.join("\n");
}

function urlEntry(lang: string, path: string, source: string) {
  const lastmod = lastmodFor(source);

  return [
    "  <url>",
    `    <loc>${urlFor(lang, path)}</loc>`,
    lastmod ? `    <lastmod>${lastmod}</lastmod>` : null,
    alternateLinks(path),
    "  </url>",
  ]
    .filter(Boolean)
    .join("\n");
}

export const GET: APIRoute = () => {
  const staticEntries = staticPaths.flatMap(({ path, source }) =>
    locales.map((lang) => urlEntry(lang, path, source)),
  );

  const docEntries = docPaths.flatMap(({ path, slug }) =>
    locales.map((lang) => urlEntry(lang, path, docSource(lang, slug))),
  );

  const body = [...staticEntries, ...docEntries].join("\n");

  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
${body}
</urlset>
`;

  return new Response(xml, {
    headers: {
      "content-type": "application/xml; charset=utf-8",
      "cache-control": "public, max-age=300",
    },
  });
};

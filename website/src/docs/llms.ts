// Builds an llms.txt (https://llmstxt.org) index: a plain-text map of the docs
// site for LLMs/crawlers to fetch instead of scraping rendered HTML. Generated
// from the same nav + frontmatter the sidebar and search index use, so it can
// never drift out of sync with the real page list.

import { docsNav, groupLabels } from "./nav";
import { locales, localeNames, type Locale } from "../i18n/ui";

const SITE = "https://pepe-agent.com";

const docs = import.meta.glob("./**/*.md", {
  eager: true,
  import: "default",
  query: "?raw",
}) as Record<string, string>;

function rawDocFor(lang: string, slug: string) {
  const key = Object.keys(docs).find((path) => path.endsWith(`/${lang}/${slug}.md`));
  if (key) return docs[key];

  const en = Object.keys(docs).find((path) => path.endsWith(`/en/${slug}.md`));
  return en ? docs[en] : "";
}

function frontmatterValue(frontmatter: string, key: string) {
  const match = frontmatter.match(new RegExp(`^${key}:\\s*(.+)$`, "m"));
  return match?.[1]?.replace(/^["']|["']$/g, "").trim() ?? "";
}

function parseFrontmatter(raw: string) {
  const match = raw.match(/^---\n([\s\S]*?)\n---\n?/);
  const frontmatter = match?.[1] ?? "";

  return {
    title: frontmatterValue(frontmatter, "title"),
    description: frontmatterValue(frontmatter, "description"),
  };
}

function parseDoc(raw: string) {
  const match = raw.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  const frontmatter = match?.[1] ?? "";
  const body = (match?.[2] ?? raw).trim();

  return {
    title: frontmatterValue(frontmatter, "title"),
    description: frontmatterValue(frontmatter, "description"),
    body,
  };
}

function hrefOf(lang: string, slug: string) {
  return slug === "index" ? `${SITE}/${lang}/docs/` : `${SITE}/${lang}/docs/${slug}/`;
}

/** Render the llms.txt body for one locale. */
export function buildLlmsTxt(lang: Locale): string {
  const intro = parseFrontmatter(rawDocFor(lang, "index"));
  const labels = groupLabels[lang];

  const sections = docsNav
    .map((group) => {
      const items = group.slugs
        .filter((slug) => slug !== "index")
        .map((slug) => {
          const { title, description } = parseFrontmatter(rawDocFor(lang, slug));
          const label = title || slug;
          return description ? `- [${label}](${hrefOf(lang, slug)}): ${description}` : `- [${label}](${hrefOf(lang, slug)})`;
        });

      if (items.length === 0) return "";
      return `## ${labels[group.group]}\n\n${items.join("\n")}`;
    })
    .filter(Boolean);

  const otherLocales = locales.filter((locale) => locale !== lang);
  const optional = [
    `- [Full text](${SITE}/${lang}/llms-full.txt): every page's content in one file, for ingesting the whole corpus at once.`,
    ...otherLocales.map((locale) => `- [${localeNames[locale]}](${SITE}/${locale}/llms.txt)`),
  ];

  return [
    `# Pepe`,
    "",
    `> ${intro.description}`,
    "",
    sections.join("\n\n"),
    "",
    "## Optional",
    "",
    optional.join("\n"),
    "",
  ].join("\n");
}

/**
 * The llms.txt spec's optional "full" companion: every page's actual content,
 * concatenated, so an LLM can ingest the whole corpus in one fetch instead of
 * following each link in llms.txt. Same page set and order as buildLlmsTxt.
 */
export function buildLlmsFullTxt(lang: Locale): string {
  const intro = parseDoc(rawDocFor(lang, "index"));

  const pages = docsNav
    .flatMap((group) => group.slugs)
    .filter((slug) => slug !== "index")
    .map((slug) => {
      const { title, body } = parseDoc(rawDocFor(lang, slug));
      return `<!-- ${hrefOf(lang, slug)} -->\n\n# ${title || slug}\n\n${body}`;
    });

  return [`# Pepe`, "", intro.body, "", "---", "", pages.join("\n\n---\n\n"), ""].join("\n");
}

import type { APIRoute } from "astro";
import { locales, type Locale } from "../../../i18n/ui";
import { allSlugs } from "../../../docs/nav";

const docs = import.meta.glob("../../../docs/**/*.md", {
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

function parseMarkdown(raw: string) {
  const match = raw.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  const frontmatter = match?.[1] ?? "";
  const body = match?.[2] ?? raw;

  return {
    title: frontmatterValue(frontmatter, "title"),
    description: frontmatterValue(frontmatter, "description"),
    body,
  };
}

function searchableText(markdown: string) {
  return markdown
    .replace(/```[\s\S]*?```/g, (block) => block.replace(/```[a-z]*|```/gi, " "))
    .replace(/<[^>]+>/g, " ")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/[`*_>#|~-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function hrefOf(lang: string, slug: string) {
  return slug === "index" ? `/${lang}/docs/` : `/${lang}/docs/${slug}/`;
}

export function getStaticPaths() {
  return locales.map((lang) => ({ params: { lang } }));
}

export const GET: APIRoute = ({ params }) => {
  const lang = params.lang as Locale;

  const items = allSlugs.map((slug) => {
    const parsed = parseMarkdown(rawDocFor(lang, slug));

    return {
      slug,
      title: parsed.title || slug,
      description: parsed.description,
      href: hrefOf(lang, slug),
      text: searchableText(`${parsed.title}\n${parsed.description}\n${parsed.body}`),
    };
  });

  return new Response(JSON.stringify({ items }), {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "public, max-age=300",
    },
  });
};

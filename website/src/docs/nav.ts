import type { Locale } from "../i18n/ui";

// Order and grouping of the docs sidebar. Item labels come from each doc's
// frontmatter title (localized); these groups give the structure.
export const docsNav: { group: string; slugs: string[] }[] = [
  { group: "start", slugs: ["index", "quickstart"] },
  { group: "core", slugs: ["agents", "channels", "scheduled"] },
  { group: "extend", slugs: ["plugins", "security", "api"] },
];

export const allSlugs = docsNav.flatMap((g) => g.slugs);

export const groupLabels: Record<Locale, Record<string, string>> = {
  en: { start: "Getting started", core: "Core", extend: "Extend" },
  es: { start: "Primeros pasos", core: "Núcleo", extend: "Ampliar" },
  "pt-br": { start: "Começando", core: "Essencial", extend: "Estender" },
  "pt-pt": { start: "Começar", core: "Essencial", extend: "Estender" },
};

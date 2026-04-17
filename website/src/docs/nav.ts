import type { Locale } from "../i18n/ui";

// Order and grouping of the docs sidebar. Item labels come from each doc's
// frontmatter title (localized); these groups give the structure. Pages are
// kept small and cross-linked so both a human and the agent (which reads the
// same docs) can load just the one they need.
export const docsNav: { group: string; slugs: string[] }[] = [
  { group: "start", slugs: ["index", "install", "quickstart"] },
  { group: "configure", slugs: ["models", "agents", "config"] },
  {
    group: "channels",
    slugs: ["channels", "telegram", "whatsapp", "slack", "discord", "msteams", "googlechat", "webhooks", "widget"],
  },
  { group: "automate", slugs: ["scheduled", "watches"] },
  { group: "api", slugs: ["api", "sessions", "auth", "websocket", "clients"] },
  { group: "extend", slugs: ["plugins", "skills"] },
  { group: "operate", slugs: ["security", "dashboard", "by-chat", "contributing"] },
];

export const allSlugs = docsNav.flatMap((g) => g.slugs);

export const groupLabels: Record<Locale, Record<string, string>> = {
  en: {
    start: "Getting started",
    configure: "Configure",
    channels: "Channels",
    automate: "Automate",
    api: "HTTP API",
    extend: "Extend",
    operate: "Administration",
  },
  es: {
    start: "Primeros pasos",
    configure: "Configurar",
    channels: "Canales",
    automate: "Automatizar",
    api: "API HTTP",
    extend: "Ampliar",
    operate: "Administración",
  },
  "pt-br": {
    start: "Começando",
    configure: "Configurar",
    channels: "Canais",
    automate: "Automatizar",
    api: "API HTTP",
    extend: "Estender",
    operate: "Administração",
  },
  "pt-pt": {
    start: "Começar",
    configure: "Configurar",
    channels: "Canais",
    automate: "Automatizar",
    api: "API HTTP",
    extend: "Estender",
    operate: "Administração",
  },
};

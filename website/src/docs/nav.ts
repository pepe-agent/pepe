import type { Locale } from "../i18n/ui";

// Order and grouping of the docs sidebar. Item labels come from each doc's
// frontmatter title (localized); these groups give the structure. Pages are
// kept small and cross-linked so both a human and the agent (which reads the
// same docs) can load just the one they need.
//
// This is the ONLY home for user-facing documentation. The repository's `docs/`
// used to carry a second, independently written copy of most of it, and the two
// drifted, which is what a second copy always does: this security page went on
// saying secrets live as ${ENV_VAR} and nothing more, for weeks after that had
// stopped being the whole story. What stays in the repo is only what a
// contributor reads and a user never does, which is not a duplicate of anything:
// the architecture, the test suite, how to add a tool, how to migrate, how to help.
export const docsNav: { group: string; slugs: string[] }[] = [
  { group: "start", slugs: ["index", "install", "docker", "quickstart"] },
  { group: "configure", slugs: ["models", "agents", "config", "secrets", "billing", "projects"] },
  { group: "capabilities", slugs: ["skills", "learning", "routing", "delegation", "admin-agents"] },
  {
    group: "channels",
    slugs: ["channels", "telegram", "voice", "documents", "whatsapp", "slack", "discord", "msteams", "googlechat", "webhooks", "widget"],
  },
  { group: "automate", slugs: ["goals", "scheduled", "flows", "board", "watches", "commitments"] },
  { group: "api", slugs: ["api", "sessions", "auth", "websocket", "clients"] },
  { group: "extend", slugs: ["plugins", "mcp"] },
  { group: "operate", slugs: ["security", "privacy", "dashboard", "backup", "by-chat", "traces", "session-search", "evals", "contributing"] },
];

export const allSlugs = docsNav.flatMap((g) => g.slugs);

export const groupLabels: Record<Locale, Record<string, string>> = {
  en: {
    start: "Getting started",
    configure: "Configure",
    capabilities: "What an agent can do",
    channels: "Channels",
    automate: "Automate",
    api: "HTTP API",
    extend: "Extend",
    operate: "Administration",
  },
  es: {
    start: "Primeros pasos",
    configure: "Configurar",
    capabilities: "Lo que un agente puede hacer",
    channels: "Canales",
    automate: "Automatizar",
    api: "API HTTP",
    extend: "Ampliar",
    operate: "Administración",
  },
  "pt-br": {
    start: "Começando",
    configure: "Configurar",
    capabilities: "O que um agente faz",
    channels: "Canais",
    automate: "Automatizar",
    api: "API HTTP",
    extend: "Estender",
    operate: "Administração",
  },
  "pt-pt": {
    start: "Começar",
    configure: "Configurar",
    capabilities: "O que um agente faz",
    channels: "Canais",
    automate: "Automatizar",
    api: "API HTTP",
    extend: "Estender",
    operate: "Administração",
  },
};

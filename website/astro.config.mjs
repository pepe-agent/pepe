import { defineConfig } from "astro/config";

// Static output; multilingual with a browser-language redirect at the root.
export default defineConfig({
  site: "https://pepe-agent.com",
  i18n: {
    defaultLocale: "en",
    locales: ["en", "es", "pt-br", "pt-pt"],
    routing: { prefixDefaultLocale: true, redirectToDefaultLocale: false },
  },
  build: { format: "directory" },
});

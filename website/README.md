# Pepe website

The public site for Pepe - a marketing landing and the documentation, in four
languages (English, Spanish, Portuguese-BR, Portuguese-PT). Built with
[Astro](https://astro.build) and output as a static site, so it deploys to
Cloudflare Pages (or any static host) with no server.

## Develop

```
npm install
npm run dev      # http://localhost:4321
npm run build    # → dist/
```

## Structure

```
src/
  pages/index.astro          # root: redirects by the browser's language
  pages/[lang]/index.astro   # the landing, per locale
  pages/[lang]/docs/[...slug].astro  # docs, per locale (falls back to English)
  layouts/, components/       # Base layout, Nav, Footer, language switcher
  i18n/ui.ts                  # landing + UI copy per locale
  docs/<locale>/*.md          # docs content (Markdown, one folder per language)
  styles/global.css           # the design system
```

To add a docs page: add its slug to `src/docs/nav.ts` and create
`src/docs/en/<slug>.md` (plus translations). Missing translations fall back to
English automatically.

## Deploy to Cloudflare Pages

Create a Pages project from this repo with:

- **Root directory:** `website`
- **Build command:** `npm run build`
- **Build output directory:** `dist`

Pages serves clean URLs (no `.html`) and gives you SSL and a custom domain for
free. The root path detects the visitor's browser language and redirects; a
language switcher in the header lets them change it.

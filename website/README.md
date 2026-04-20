# Pepe website

The public site for Pepe - a marketing landing and the documentation, in four
languages (English, Spanish, Portuguese-BR, Portuguese-PT). Built with
[Astro](https://astro.build) and output as a static site, deployed as a
Cloudflare Worker that serves it (see `worker.js`, `wrangler.jsonc`) - or to
any static host, if you'd rather skip Cloudflare and the optional password
gate below.

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

## Deploy to Cloudflare (Workers, connected to this repo)

This deploys as a **Worker**, not classic Cloudflare Pages: `worker.js` runs
in front of the built site (`wrangler.jsonc` sets `assets.run_worker_first`)
so it can optionally gate the whole site behind a password before falling
through to the static files. In the Cloudflare dashboard, connect a Worker to
this repo with:

- **Production branch:** `master`
- **Build command:** `npm run build`
- **Deploy command:** `npx wrangler deploy`
- **Root directory** (under Advanced settings): `website` - easy to miss, and
  without it Cloudflare looks for `package.json`/`wrangler.jsonc` at the repo
  root and finds neither.

There's no separate "build output directory" field to set - `wrangler.jsonc`
already points at `dist` via `assets.directory`.

Cloudflare gives you SSL and a custom domain for free, and the Worker serves
clean URLs (no `.html`). The root path detects the visitor's browser language
and redirects; a language switcher in the header lets them change it.

### Password-gating the site

`worker.js` answers every request with HTTP Basic Auth if the Worker has a
`SITE_PASSWORD` variable set (Cloudflare dashboard -> the Worker -> Settings
-> Variables and Secrets); `SITE_USER` is optional (defaults to `pepe`). Leave
`SITE_PASSWORD` unset to keep the site open - the default, and what you want
once it's ready for visitors.

### Deploying elsewhere

Nothing here is Cloudflare-specific except `worker.js`/`wrangler.jsonc`. `npm
run build` alone produces a plain static site in `dist/` that any static host
can serve.

---
title: Browser
description: An agent can drive a real headless browser for pages that need JavaScript, a login, or clicking through a flow.
---

`fetch_url` is a plain HTTP GET: it can't render JavaScript, log in, or click anything. The `browser` tool is for the pages that need that - a real, headless Chrome, driven one page at a time, that persists across calls in the same conversation until you close it.

Each conversation gets its own browser session, started the first time it calls `open` and closed automatically after ten idle minutes if nothing ends it explicitly. Its cookies and current page carry over from one call to the next, so a login, a multi-step form, or a page that only reveals content after a click all work the way they would in a real tab.

## What it can do

- **`open`** - navigate to a URL (starts the session's browser if none is running yet). Returns the page's title, its visible text, and a numbered list of the elements you can act on.
- **`snapshot`** - re-describe the current page, same shape as `open`, without navigating - useful after a script on the page changes something without a full page load.
- **`click`** - click the element numbered `ref` from the last `open`/`snapshot`.
- **`type`** - type text into the element numbered `ref`.
- **`press`** - press a keyboard key (e.g. "Enter"), optionally focused on an element first.
- **`close`** - end the session and free its browser.

```
You: Log into the status page and tell me if anything's down.

Agent: [browser open: "https://status.example.com/login"]
       [browser type ref=2: "the account email"]
       [browser type ref=3: "the account password"]
       [browser click ref=4]
       [browser snapshot]
Everything's green - no open incidents right now.
```

Elements are addressed by number, not by a CSS selector you'd have to write yourself: every `open`/`snapshot` tags each clickable or fillable element and hands back what it is and what it says, so an agent reads "element 4 is the submit button" off what it was just shown.

## Security posture

A browser under an agent's control reaches the same network the app does, so `browser` enforces the same rule `fetch_url` does: only `http`/`https`, and never an internal or private address (loopback, RFC1918, link-local, cloud metadata). And because a real browser is a materially bigger surface than a read-only tool - the page's own scripts run, a signed-in session could be exposed, it uses real CPU and memory - `browser` is not always-safe: every call goes through the same permission prompt as `bash`.

## Getting a browser

`browser` needs an actual Chrome/Chromium/Edge/Brave binary to drive. It looks in this order:

1. `PEPE_CHROME_BINARY`, if you set it - an explicit path wins over everything else.
2. Whatever's already installed - checked on `PATH` and in each OS's normal install locations (`/Applications` on macOS, `Program Files` and the per-user install folder on Windows), so a browser you already have is used as-is, container or not.
3. **A one-time automatic download** if neither of those found anything: a small, display-less `chrome-headless-shell` build from Google's own Chrome for Testing feed, cached under `~/.cache/pepe/browser/` so this only happens once per machine. Turn it off with `PEPE_BROWSER_AUTO_DOWNLOAD=0` if you'd rather install one yourself and see a clear error instead.

The default image doesn't include the browser package itself (the same reasoning that keeps ffmpeg out - see the Dockerfile) - but it does include the shared libraries `chrome-headless-shell` needs to actually launch once downloaded, since `browser` is a built-in tool, not an optional extra. So step 3 is what runs by default in Docker, and it works out of the box: no build arg needed, on an `amd64` host (Google doesn't publish a Chrome for Testing build for Linux on ARM - see below). If you'd rather bake a full browser into the image instead of downloading at runtime:

```
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="chromium" .
```

## Linux on ARM

Chrome for Testing has no Linux ARM build, so step 3 can't help there - `browser` returns a clear "unsupported platform" error instead of silently failing. Install Chromium yourself via your system's package manager and put it on `PATH`, or set `PEPE_CHROME_BINARY`.

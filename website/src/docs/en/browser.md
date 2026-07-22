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

## Chrome required

`browser` needs an actual Chromium or Chrome binary on the machine running Pepe - it isn't installed by default, in the container or otherwise. In Docker, opt in at build time:

```
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="chromium" .
```

Outside Docker, install Chromium (or Chrome) and make sure it's on `PATH`, or point `PEPE_CHROME_BINARY` at its executable. With neither, `browser` returns a clear error instead of failing silently.

---
title: Fetch URL
description: An agent's fetch_url tool reads a page's actual content by default, not the raw HTML around it.
---

`fetch_url` is a plain HTTP GET, but an HTML response isn't handed back as-is: by default it's boiled down to the page's actual readable text first. Nav bars, cookie banners, footers, and ad markup would only crowd the conversation without ever being the answer to what the agent fetched the page for.

```
You: What does this blog post say about the new release?
    [fetch_url: "https://example.com/blog/new-release"]

Agent: [reads the actual article text, none of the site's nav/footer around it]
The post covers three changes: ...
```

## When you want the raw markup instead

Pass `raw: true` to skip extraction and get the response body exactly as the server sent it. That's useful for an API response, source code, or a page where you need the literal HTML (attributes, structure, embedded data), not its prose.

```
fetch_url url: "https://example.com/product/123" raw: true
```

Extraction only ever applies to a `text/html` response in the first place; a JSON or plain-text fetch is never touched. And it degrades gracefully: a page with nothing extractable (a link list, a page that's mostly navigation, a very large document) falls back to the raw body automatically, the same as `raw: true` would have gotten you, rather than returning something misleadingly empty.

The cleanup is plain text processing, not a model call: it adds no delay and no cost, and it works the same regardless of which model the agent itself is using.

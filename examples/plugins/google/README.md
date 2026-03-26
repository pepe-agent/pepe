# Google Workspace tools (example plugin)

Calendar and Gmail as agent **tools**, shipped as a drop-in plugin. It implements
the `Pepe.Tools.Tool` behaviour, so `Pepe.Tools.all/0` discovers it with no core
change; grant an agent any of the tool names and it can use them.

## Tools

| Tool | What it does |
|------|--------------|
| `gcal_upcoming` | List upcoming events on the primary calendar |
| `gcal_create_event` | Create an event (summary, start, end, description) |
| `gmail_search` | Search Gmail; returns sender + subject of matches |
| `gmail_send` | Send a plain-text email |

## Install

```bash
mix pepe plugin install examples/plugins/google
```

Then give an agent the tools it should have:

```bash
mix pepe agent add assistant --tools gcal_upcoming,gcal_create_event,gmail_search,gmail_send
```

## Auth (OAuth2)

Google APIs use OAuth2 bearer tokens. The plugin reads credentials from the
environment at call time, so nothing sensitive lands in `config.json`. Two ways:

**A. A ready access token (quickest, expires in ~1h)**

```bash
export GOOGLE_ACCESS_TOKEN=ya29....
```

**B. A refresh token (survives expiry; the plugin mints access tokens per call)**

```bash
export GOOGLE_CLIENT_ID=...apps.googleusercontent.com
export GOOGLE_CLIENT_SECRET=...
export GOOGLE_REFRESH_TOKEN=...
```

To get these: create an OAuth client (type "Desktop app") in a Google Cloud
project, enable the Calendar and Gmail APIs, and run the consent flow once for
the scopes you need:

- `https://www.googleapis.com/auth/calendar`
- `https://www.googleapis.com/auth/gmail.modify`

The consent step returns the refresh token you export above. (A future
`mix pepe oauth login google` can automate this by reusing `Pepe.OAuth`, which
already does the Authorization-Code + PKCE loopback flow.)

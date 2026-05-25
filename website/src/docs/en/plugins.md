---
title: Plugins
description: Extend Pepe with your own tools and channels by installing plugins with their own settings.
---

A plugin adds a **tool** the model can call, or a **channel provider** (a new
messaging platform), or both: Elixir compiled at runtime from
`~/.pepe/plugins/`, no rebuild. These are the only two shapes a plugin can take
today; a module is matched against whichever shape it implements.

## The Tool behaviour

```elixir
@callback name() :: String.t()
@callback spec() :: map()
@callback run(args :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:error, String.t()}
```

| Callback | Purpose |
|---|---|
| `name/0` | The function name the model calls, e.g. `"read_file"`. Must be unique across all tools; a plugin never wins a name collision with a built-in. |
| `spec/0` | The OpenAI-style function spec: name, plain-language description, and a JSON Schema for the parameters. This is what the model reads to decide when and how to call the tool. |
| `run/2` | Runs the call. `args` is the decoded arguments (a string-keyed map); `ctx` carries the current run's context (below). Return `{:ok, text}` or `{:error, message}`; either way it's turned into a string and fed back to the model, so write it for the model to read. |

`Pepe.Tools.Tool.function/3` builds the spec envelope for you, so you only
supply the name, description, and parameters.

A complete, working tool, saved as an `.exs` and installed (see below):

```elixir
defmodule MyPlugin.Reverse do
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "reverse_text"

  @impl true
  def spec do
    function("reverse_text", "Reverse the characters in a piece of text.", %{
      "type" => "object",
      "properties" => %{
        "text" => %{"type" => "string", "description" => "The text to reverse."}
      },
      "required" => ["text"]
    })
  end

  @impl true
  def run(%{"text" => text}, _ctx) do
    {:ok, String.reverse(text)}
  end

  def run(_args, _ctx), do: {:error, "missing 'text'"}
end
```

The second `run/2` clause is good practice: if the model omits a required
argument, return a clear error instead of crashing (a crash is caught too, but
a tailored message helps the model recover on the next turn).

**`ctx`**, the second argument to `run/2`, carries the current run: `ctx[:agent]`
(the running agent, e.g. `%{name: "assistant"}`), `ctx[:session_key]` (the live
conversation, absent for one-shot runs), `ctx[:cwd]` (the working directory).
Treat every key as optional. Tools that read/write files resolve paths through
`Pepe.Agent.Workspace`; tools that call an outside API usually ignore `ctx`
entirely and just reach for the bundled `Req` HTTP client, no extra dependency
needed.

## The Channel provider behaviour

A channel provider teaches Pepe to speak a new messaging platform over the
existing generic inbound webhook: no new route, just a new module in the
registry.

```elixir
@callback name() :: String.t()
@callback verify(config :: map(), params :: map()) :: {:ok, String.t()} | :error
@callback authenticate(config :: map(), raw_body :: binary(), headers :: map()) :: :ok | :error
@callback parse(payload :: map()) :: {:ok, [inbound]} | :ignore
@callback deliver(config :: map(), to :: String.t(), text :: String.t()) :: :ok | {:error, term()}
```

| Callback | Required? | Purpose |
|---|---|---|
| `name/0` | yes | Registry key and the `:provider` segment of the webhook URL, e.g. `"whatsapp"`. |
| `verify/2` | yes | Answers the platform's handshake `GET` when you register the webhook URL. `{:ok, challenge}` or `:error` if the provider has none. |
| `authenticate/3` | yes | Checks an inbound `POST`'s signature against the connection's secret. `:ok` to accept, `:error` to drop it. |
| `parse/1` | yes | Normalizes a decoded payload into zero or more `%{from, text, id}` messages, or `:ignore` for things with nothing to act on (receipts, status updates). |
| `deliver/3` | yes | Sends a text reply to `to` (a provider address: phone number, channel id, ...). |
| `label/0` | no | Human label for the dashboard (defaults to `name/0`). |
| `config_schema/0` | no | Fields the dashboard renders to configure a connection, same shape as a plugin manifest's `config` array (below). |
| `respond/3` | no | A **synchronous** HTTP reply to the raw `POST`, for protocols that need one before any agent work (Slack's URL-verification challenge, Discord's `PING`). `{:reply, status, content_type, body}` or `:cont` to fall through to `parse/1`. |
| `deliver_file/4` | no | Sends a file as an attachment. Omit it and `send_file` just reports the channel can't receive files. |
| `addressed?/2` | no | Does this payload address the bot, so it should get a reply? Lets a provider honor `require_mention` in group chats (default when omitted: always addressed). |

## The registry

`Pepe.Tools.all/0` returns the built-in tools followed by every loaded plugin
tool; `Pepe.Webhooks` does the same for channel providers. Built-ins and
plugins are merged into a single registry, and the two shapes settle a name
collision in opposite ways. For tools, a built-in always wins, so pick a tool
name distinct from `read_file`, `web_search`, and the rest of `pepe tools`. For
channel providers, a plugin of the same name wins, which is how you replace a
bundled provider with your own version of it.

### Granting a tool to an agent

Installing a plugin does not hand its tools to every agent; only the tools
listed on an agent are exposed to it, gated the same as a built-in.

**CLI:** `pepe agent add assistant --tools reverse_text,web_search,read_file`

**Dashboard:** open the agent under Agents and tick the tool; plugin tools
appear alongside built-ins.

**By chat:** an agent with `enable_tool` can turn on a tool for itself:

> You: enable the reverse_text tool
>
> Agent: enabled reverse_text; you can use it from your next message

To grant a tool to a *different* agent, `manage_agent`'s `add_tool` action does
it (scoped to the agents the caller is allowed to manage, confirms with you
first):

> You: give the support agent the gmail_search tool
>
> Agent: I will add gmail_search to the "support" agent. Confirm?

## Where plugins live and how they load

Plugins live under `~/.pepe/plugins/` (follows `PEPE_HOME`). Pepe scans that
folder recursively for `.exs` files, compiles each once, and recompiles only
when its mtime changes. Drop a file in, it works with no restart; edit it,
the change lands on the next tool call. One file can define several modules
(the Google example below ships four).

A plugin is one of two shapes: a bare `.exs` file, or a **package** (a
directory with a `manifest.json` and one or more `.exs` files).

Runtime compilation carries one honest limit: **a plugin cannot bring a new
external dependency with it.** Elixir resolves and compiles dependencies at
build time, so a plugin can only use the libraries Pepe already ships (`Req`,
`Jason`, the standard library, and the rest of its deps). A plugin that needs a
brand-new library is not a drop-in; it would mean rebuilding Pepe. In practice
this is rarely a constraint, since a tool that calls an HTTP API and a channel
provider like Chatwoot need nothing beyond what is already bundled, which is
why they install cleanly.

## Installing a plugin

The source is a local file, a local directory, a `.tar.gz`, or a URL to any of
those, and `install` unrolls whatever you give it into the plugins directory. A
GitHub repo URL is fetched as its source archive and extracted, taking the
default branch (`main`, then `master`) when no branch is given; add
`/tree/<branch>` to the URL to take a different one. A `.tar.gz`, local or
remote, is extracted and the package placed under the `name` from its manifest.
A directory is copied in as it is, and a bare `.exs` file is copied straight
across.

**CLI:**

```bash
pepe plugin install ./my_plugin.exs
pepe plugin install https://github.com/you/pepe-myplugin
pepe plugin list
pepe plugin remove google
```

**Dashboard:** the Plugins page takes a GitHub URL, `.tar.gz` URL, or local
path; you tick a box confirming you trust the source, then Install. Installed
plugins list with a Remove button and, when the plugin declares settings, a
Configure button.

**From chat, with `manage_plugin`:** an agent holding this tool can install on
your behalf: `scan` a source first to see what it does, then `install`,
`list`, `remove`. It runs the same security scan as the CLI, but with no
`--force` escape hatch: a dangerous verdict is always refused from chat, and
the agent will tell you to review the code and run `--force` yourself at a
terminal if you still want it.

## The security scan

A plugin is ordinary Elixir with full access to the running app; installing
one is a trust decision, like adding any dependency. Install only from a source
you trust, and prefer pinning a specific version or commit.

Before it's placed on disk, `Pepe.Skills.Sentinel` statically scans it. It
walks the **parse tree** rather than the raw text, so it flags dangerous calls
precisely:

- shelling out (`System.cmd`, `:os.cmd`),
- dynamic eval (`Code.eval_string`),
- unsafe deserialization (`:erlang.binary_to_term`),
- destructive filesystem calls (`File.rm_rf`),
- atom exhaustion (`String.to_atom`),
- reading the environment or secret paths (`~/.ssh`, the Pepe config),
- network access.

Because it reads the AST, it catches the aliased and Erlang forms of those
calls too, and it does not trip over the same words when they appear in a
comment or a string. It never executes the code, and returns one of three
verdicts:

- **clean**: no findings.
- **caution**: flagged but often legitimate (a channel plugin *should* make
  network calls); shown, doesn't block.
- **danger**: no good reason to be here; blocks the install.

```bash
pepe plugin scan ./my_plugin.exs        # scan without installing
pepe plugin install ./risky.exs --force # proceed anyway, after you've reviewed it
```

<div class="note"><strong>A plugin runs with full access.</strong> The scan is
a safety net, not a substitute for reading the code yourself.</div>

## The manifest and the Configure dialog

A package's `manifest.json` names it, describes it, and, most usefully,
declares the settings it needs. From the bundled Google example:

```json
{
  "name": "google",
  "version": "0.1.0",
  "description": "Google Workspace tools: read/create Calendar events and search/send Gmail, as agent tools.",
  "provides": ["tool:gcal_upcoming", "tool:gcal_create_event", "tool:gmail_search", "tool:gmail_send"],
  "files": ["google.exs"],
  "config": [
    {"key": "access_token", "label": "Access token", "type": "secret", "hint": "ya29... (expires in ~1h); or fill the refresh trio below. Store as ${ENV_VAR} to keep it out of the file."},
    {"key": "client_id", "label": "OAuth client ID", "type": "text", "hint": "...apps.googleusercontent.com"},
    {"key": "client_secret", "label": "OAuth client secret", "type": "secret"},
    {"key": "refresh_token", "label": "Refresh token", "type": "secret", "hint": "minted once from the consent flow; survives access-token expiry"}
  ]
}
```

Each `config` entry is one field: `key` (the name your code reads), `label`
(shown in the form), `type` (`"text"`, `"secret"` for a masked input, or
`"select"` with an `"options"` list), and an optional `hint`. The dashboard
reads this array and renders the Configure dialog; a new plugin needs no new
screen. A value can be a `${ENV_VAR}` reference, stored literally and resolved
from the environment only when read, so secrets never sit expanded in the
config file.

Read a saved setting from your plugin's code with `Pepe.Plugins.config/3`
(name is the package name from the manifest; the third argument is a default):

```elixir
token = Pepe.Plugins.config("google", "access_token")
region = Pepe.Plugins.config("myplugin", "region", "us-east-1")
```

A common pattern: prefer the dashboard value, fall back to an environment
variable, so the plugin works whether the operator fills the form or exports a
variable (the Google example below does exactly this).

## Example: the Google Workspace tool plugin

`examples/plugins/google/google.exs` ships four tools in one file:

| Tool | What it does |
|------|--------------|
| `gcal_upcoming` | List upcoming events on the primary Google Calendar |
| `gcal_create_event` | Create an event (summary, start, end, description) |
| `gmail_search` | Search Gmail and return sender and subject of matches |
| `gmail_send` | Send a plain-text email |

```bash
pepe plugin install ./examples/plugins/google
pepe agent add assistant --tools gcal_upcoming,gcal_create_event,gmail_search,gmail_send
```

It authenticates with an OAuth2 bearer token resolved at call time; nothing
sensitive baked into the code. Either export a ready access token (quickest,
expires in ~1h):

```bash
export GOOGLE_ACCESS_TOKEN=ya29....
```

or a refresh token (survives expiry; the plugin mints an access token per
call):

```bash
export GOOGLE_CLIENT_ID=...apps.googleusercontent.com
export GOOGLE_CLIENT_SECRET=...
export GOOGLE_REFRESH_TOKEN=...
```

Get these from an OAuth client (type "Desktop app") in a Google Cloud project,
with the Calendar and Gmail APIs enabled, after running the consent flow once
for the scopes you use. Or fill the same fields in the plugin's Configure
dialog, storing secrets as `${ENV_VAR}` references.

One tool's full source, showing the pattern end to end:

```elixir
defmodule Pepe.Plugins.GCalUpcoming do
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]
  alias Pepe.Plugins.Google.API

  @impl true
  def name, do: "gcal_upcoming"

  @impl true
  def spec do
    function("gcal_upcoming", "List upcoming events on the user's primary Google Calendar.", %{
      "type" => "object",
      "properties" => %{
        "max" => %{"type" => "integer", "description" => "How many events to return (default 10)."}
      }
    })
  end

  @impl true
  def run(args, _ctx) do
    max = args["max"] || 10
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    API.with_token(fn token ->
      params = [maxResults: max, orderBy: "startTime", singleEvents: true, timeMin: now]

      case API.get("https://www.googleapis.com/calendar/v3/calendars/primary/events", token, params) do
        {:ok, %{"items" => items}} -> {:ok, format_events(items)}
        {:ok, _} -> {:ok, "No upcoming events."}
        error -> error
      end
    end)
  end
end
```

> You: what's on my calendar tomorrow, and email a summary to sam@example.com
>
> Agent: (calls gcal_upcoming, then gmail_send) You have 3 events tomorrow. I emailed the summary to sam@example.com.

## Example: the Chatwoot channel plugin

`examples/plugins/chatwoot/` shows the other shape: a **channel**, not a tool.
It registers a `chatwoot` provider so Pepe can sit behind a
[Chatwoot](https://www.chatwoot.com) inbox as the AI agent, across every
channel Chatwoot owns (WhatsApp, web widget, Instagram, ...).

```bash
pepe plugin install ./examples/plugins/chatwoot
```

**Native human handoff, no extra glue.** Chatwoot carries the handoff signal
in every webhook: the conversation `status`. The plugin implements `parse/1`
to answer only conversations marked `pending` (bot-owned); the moment a human
agent takes over (`open`), Pepe goes quiet, and resumes when it's back to
`pending`.

**Setup, in Chatwoot:** create an AgentBot, point its outgoing webhook at
`https://YOUR_HOST/webhooks/<project>/chatwoot/<slug>`. The connection holds
`base_url`, `account_id`, and an `api_token` (as a `${ENV_VAR}`) via
`config_schema/0`, filled from the dashboard, same Configure pattern as any
plugin.

> This is one of two mutually exclusive ways to run WhatsApp: **either**
> WhatsApp direct in Pepe (the built-in `whatsapp` provider) **or** WhatsApp on
> Chatwoot with Pepe behind it (this plugin). Never connect the same number to
> both.

## Delivering a file, not just text

A tool's `run/2` only ever returns text. To hand the person in the
conversation an actual file (a spreadsheet, a PDF), don't reinvent delivery;
call the built-in `send_file` tool with a path; Pepe resolves the channel from
the session and delivers it there. Grant `send_file` to an agent and it just
works from chat, on any channel whose provider implements `deliver_file/4`.

## Checklist

**Writing a tool:**

1. Implement `name/0`, `spec/0`, `run/2`; give it a name distinct from every
   built-in.
2. Return `{:ok, text}` / `{:error, message}` from `run/2`, written for the
   model to read.
3. Need credentials or options? Ship a `manifest.json` with a `config` array,
   read them with `Pepe.Plugins.config/3`.

**Writing a channel:**

1. Implement `name/0`, `verify/2`, `authenticate/3`, `parse/1`, `deliver/3`;
   add `config_schema/0` if it needs dashboard-configured credentials.
2. Add `respond/3` only if the platform's protocol needs a synchronous reply
   before any agent work; `deliver_file/4` only if it can receive attachments.

**Either way:** scan it (`pepe plugin scan SRC` or `manage_plugin scan`),
install it, review what the scan found, then grant the tool to an agent (CLI,
dashboard, or `enable_tool`/`manage_agent` from chat); a channel needs no
grant, it's live the moment it's installed.

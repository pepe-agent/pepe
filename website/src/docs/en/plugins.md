---
title: Plugins
description: Extend Pepe with your own tools (and channels) at runtime by dropping an Elixir file into the plugins folder. No rebuild, no core change.
---

Pepe ships with a set of built-in tools: run a shell command, read and write
files, fetch a URL, search the web, send a file to the current chat, and more. A
plugin lets you add your own without touching the core or recompiling the app.
Drop a file into the plugins folder and it works on the next tool call.

A plugin can add two kinds of thing:

- A **tool**. A small module the model can call during the agent loop. This is
  the common case and the focus of this page.
- A **channel provider**. A module that teaches Pepe to talk to a new messaging
  platform over the generic inbound webhook. Same loader, a different shape.

## How a tool works

An agent runs a loop. It calls the model, the model may ask to call one or more
tools, Pepe runs them, feeds the results back, and repeats until the model
returns a final answer. A tool is a named function the model is allowed to call.
You describe it with a JSON spec (name, description, parameters) so the model
knows when and how to call it, and you provide the code that runs when it does.

Every tool, built-in or plugin, implements the same three-function contract.

### The Tool behaviour

```elixir
@callback name() :: String.t()
@callback spec() :: map()
@callback run(args :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:error, String.t()}
```

- `name/0` is the function name the model calls, for example `"read_file"`. It
  must be unique across all tools.
- `spec/0` returns the OpenAI-style function spec: a name, a plain-language
  description, and a JSON Schema for the parameters. The model reads this to
  decide when to call the tool and what arguments to pass.
- `run/2` receives the decoded `args` (a plain map with string keys, already
  parsed from the model's JSON) and a `ctx` map with information about the
  current run. It returns `{:ok, text}` on success or `{:error, message}` on
  failure. Either way the result is turned into a string and fed back to the
  model as the tool's answer, so write it for the model to read.

A helper, `Pepe.Tools.Tool.function/3`, builds the standard spec envelope for
you, so you only fill in the name, description, and parameters.

### A minimal tool

Here is a complete, working tool that reverses a string. Save it as an `.exs`
file and install it (see below).

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

That is the whole pattern. The second `run/2` clause is a good habit. If the
model calls the tool without the required argument, you return a clear error
instead of crashing. A crash is caught and reported too, but a tailored message
helps the model recover on the next turn.

### What is in ctx

The `ctx` map carries the context of the current run. The keys you are most
likely to use:

- `ctx[:agent]` is the agent that is running, for example `%{name: "assistant"}`.
- `ctx[:session_key]` identifies the live conversation when there is one (a chat
  on a messaging channel, a WebSocket session). It is absent for one-shot runs.
- `ctx[:cwd]` is the working directory for the run.

Tools that read or write files use `Pepe.Agent.Workspace` to resolve paths
against the agent's persistent workspace. Tools that talk to the outside world
(an HTTP API, a database) usually ignore `ctx` entirely. Treat every key as
optional and match defensively.

<div class="note"><strong>Use the bundled Req for HTTP.</strong> Pepe already
depends on the Req HTTP client, so your plugin can call any web API with no extra
dependency. See how the built-in <code>web_search</code> and the Google example
below do it.</div>

## The registry: how tools are found

`Pepe.Tools` is the single registry. It combines two sources.

- The **built-in** set, a fixed list in `Pepe.Tools`. It includes `bash`,
  `run_script`, `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir`,
  `fetch_url`, `web_search`, `send_file`, and the management tools an agent uses
  to run the runtime by chat (`manage_agent`, `manage_channel`, `enable_tool`,
  `schedule_task`, and others).
- **Plugins**, discovered at runtime from the plugins folder.

`Pepe.Tools.all/0` returns the built-ins followed by every loaded plugin tool.
When you list an agent's tools, each name is looked up here. There is one rule to
know: on a name collision, the built-in wins. You cannot shadow `read_file` with
a plugin of the same name, so pick a distinct name for your tool.

### Granting a tool to an agent

A plugin being installed does not automatically hand its tools to every agent.
Only the tools you list on an agent are exposed to it, and each call still
passes through the same permission gate as a built-in tool. You grant a tool
three ways.

**With the pepe CLI.** List the tool in the agent's `--tools`:

```bash
pepe agent add assistant --tools reverse_text,web_search,read_file
```

**On the dashboard.** Open the agent under Agents and tick the tool in its tool
list. The plugin's tools appear alongside the built-ins.

#### Do it by chat

An agent that has the `enable_tool` built-in can turn a tool on for itself
after you install a plugin, without you touching the CLI or dashboard.

> You: enable the reverse_text tool
>
> Agent: enabled reverse_text; you can use it from your next message

`enable_tool` only accepts a tool that already exists as a built-in or a loaded
plugin, and the change takes effect on the agent's next message. To grant a tool
to a *different* agent, an agent with the `manage_agent` tool can do it with the
`add_tool` action. That tool is scoped to the agents the acting agent is allowed
to manage, and its instructions tell it to confirm the change with you before
applying it.

> You: give the support agent the gmail_search tool
>
> Agent: I will add gmail_search to the "support" agent. Confirm?
>
> You: yes
>
> Agent: added gmail_search to support.

## Where plugins live and how they load

Plugins live under `~/.pepe/plugins/` (the base folder follows `PEPE_HOME` if you
set it). Pepe scans that folder recursively for `.exs` files, compiles each one
once, and caches it. When a file's modification time changes, it is recompiled on
the next call. Drop a file in and it works with no restart. Edit it and the
change takes effect on the next tool call.

Each loaded module is matched against the shape a consumer wants. A module that
exports `name/0`, `spec/0`, and `run/2` is treated as a tool. A module that
exports `name/0` plus the channel provider callbacks is treated as a channel.
One file can define several modules, so a single plugin can ship a handful of
related tools (the Google example ships four).

## Installing a plugin

The source can be a local file, a local directory, a compressed archive, or a
URL to any of those. A GitHub repository URL is fetched as its source archive
(when no branch is given, `main` then `master` is tried).

**With the pepe CLI:**

```bash
pepe plugin install ./my_plugin.exs
pepe plugin install ./examples/plugins/google
pepe plugin install https://github.com/you/pepe-myplugin
pepe plugin install https://example.com/pepe-myplugin.tar.gz
```

List what is installed, and remove by name:

```bash
pepe plugin list
pepe plugin remove google
```

**On the dashboard.** The Plugins page has an install field that accepts a GitHub
repo URL, a `.tar.gz` URL, or a local path. You tick a box confirming you trust
the source, then Install. Installed plugins are listed with a Remove button and,
when the plugin declares settings, a Configure button (see below).

A bare `.exs` file is copied straight into the plugins folder. A **package** is
copied as a folder. A package is a directory that contains a `manifest.json` and
one or more `.exs` files.

## The security scan

A plugin is ordinary Elixir with full access to the running app. Installing one
is a trust decision, the same as adding any dependency. To make that decision
informed, Pepe statically scans the code before it is placed on disk. The scan
reads the syntax tree looking for dangerous patterns (spawning shells, network
calls, obfuscation, reading secrets). It never executes the code, and it returns
one of three verdicts: clean, caution, or danger.

A verdict of danger blocks the install. You can proceed anyway, after reviewing
the code, by passing `--force` on the CLI (or the "Install anyway" button on the
dashboard, which appears only after a danger verdict):

```bash
pepe plugin install ./risky_plugin.exs --force
```

You can also scan a source without installing it:

```bash
pepe plugin scan ./my_plugin.exs
```

<div class="note"><strong>A plugin runs with full access.</strong> It is
admin-level code. Install only from a source you know and trust, and read it
first. The scan is a safety net, not a substitute for review.</div>

## The manifest and the Configure dialog

A package can carry a `manifest.json`. It names the package, describes it, lists
what it provides, and, most usefully, declares the settings it needs. Here is the
manifest from the Google example:

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

The `config` array is the interesting part. Each entry describes one field:

- `key` is the setting name your code reads.
- `label` is the human label shown in the form.
- `type` is `"text"`, `"secret"` (masked input), or `"select"` (add an
  `"options"` list).
- `hint` is optional help text shown under the field.

The dashboard reads this array and renders a Configure dialog for the plugin, so
a new plugin needs no new screen. A value you enter can be a `${ENV_VAR}`
reference. It is stored as the literal reference and resolved from the
environment only when read, so secrets never sit expanded in the config file.

### Reading your settings from code

Inside the plugin, read a saved setting with `Pepe.Plugins.config/3`. It returns
the saved value with any `${ENV_VAR}` reference already resolved, or the default
when unset:

```elixir
token = Pepe.Plugins.config("google", "access_token")
region = Pepe.Plugins.config("myplugin", "region", "us-east-1")
```

The first argument is the plugin name (the package name from the manifest). This
is the bridge from the dashboard form to your running code. A common pattern is
to prefer the dashboard value and fall back to an environment variable, so the
plugin works whether the operator fills the form or exports a variable.

## Sending a file back to the chat

Tools return text to the model. When you want to deliver an actual file to the
person in the conversation (a spreadsheet, a PDF, an image), the built-in
`send_file` tool does it. Your agent produces the file however it likes, for
example a `bash` command that queries a database and writes an `.xlsx`, then
calls `send_file` with the path. Pepe looks up which channel the conversation is
on from the session and delivers the file there, so the agent never needs to know
chat ids or tokens.

`send_file` takes a `path` (absolute, or relative to the run's working directory)
and an optional `caption`. It works on any channel whose provider supports
attachments (Telegram, WhatsApp, Slack, Discord, and others). If the channel
cannot receive files, or the run is not a live chat, the tool reports that
plainly to the model. Because it is a built-in, you get this for free: just grant
the `send_file` tool to the agent.

This is also a chat capability. An agent that has `send_file` will use it when
you ask for a file in the conversation.

> You: export last month's orders as a spreadsheet and send it to me here
>
> Agent: (runs a query, writes orders.xlsx, calls send_file) Sent orders.xlsx to the conversation.

## Example: the Google Workspace plugin

Pepe bundles a complete example plugin under `examples/plugins/google`. A single
`google.exs` file defines four tools:

| Tool | What it does |
|------|--------------|
| `gcal_upcoming` | List upcoming events on the primary Google Calendar |
| `gcal_create_event` | Create an event (summary, start, end, description) |
| `gmail_search` | Search Gmail and return sender and subject of matches |
| `gmail_send` | Send a plain-text email |

Install it and grant the tools to an agent:

```bash
pepe plugin install ./examples/plugins/google
pepe agent add assistant --tools gcal_upcoming,gcal_create_event,gmail_search,gmail_send
```

The plugin shows the whole pattern in one file: several tool modules that each
implement the behaviour, a small shared helper module for auth and HTTP, and a
manifest that drives the Configure dialog.

### How it authenticates

Google APIs use OAuth2 bearer tokens. The plugin resolves a token at call time,
so nothing sensitive is baked into the code. It reads its settings from the
dashboard config first and falls back to environment variables, which means it
works whether you fill the Configure form or export variables. There are two ways
to supply credentials.

**A. A ready access token** (quickest; expires in about an hour):

```bash
export GOOGLE_ACCESS_TOKEN=ya29....
```

**B. A refresh token** (survives expiry; the plugin mints an access token per call):

```bash
export GOOGLE_CLIENT_ID=...apps.googleusercontent.com
export GOOGLE_CLIENT_SECRET=...
export GOOGLE_REFRESH_TOKEN=...
```

To get these, create an OAuth client (type "Desktop app") in a Google Cloud
project, enable the Calendar and Gmail APIs, and run the consent flow once for
the scopes you use (`https://www.googleapis.com/auth/calendar` and
`https://www.googleapis.com/auth/gmail.modify`). You can also enter the same
values in the plugin's Configure dialog on the dashboard, storing secrets as
`${ENV_VAR}` references to keep them out of the file.

Here is the shape of one of the tools, so you can see the API pattern end to end:

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

Once the tools are granted and credentials are set, the agent uses them in plain
conversation.

> You: what's on my calendar tomorrow, and email a summary to sam@example.com
>
> Agent: (calls gcal_upcoming, then gmail_send) You have 3 events tomorrow. I emailed the summary to sam@example.com.

## Channel providers, briefly

The same loader powers messaging channels. A channel plugin is a module that
exports `name/0` plus the inbound webhook provider callbacks (`verify`,
`authenticate`, `parse`, `deliver`, and optionally `respond`, `deliver_file`, and
a `config_schema` for its own Configure dialog). Once installed, the provider
becomes reachable at the generic inbound webhook route without adding a new URL,
and it shows up under the channel providers in `pepe plugin list`. The bundled
Chatwoot example under `examples/plugins/chatwoot` runs Pepe behind a Chatwoot
inbox with native human handoff. The messaging channels page covers the provider
contract in full.

## Checklist for writing your own tool

1. Write a module that implements `name/0`, `spec/0`, and `run/2`.
2. Give it a unique name (built-ins win a collision, so avoid their names).
3. Return `{:ok, text}` or `{:error, message}` from `run/2`, written for the
   model to read.
4. If it needs credentials or options, ship a `manifest.json` with a `config`
   array and read them with `Pepe.Plugins.config/3`.
5. Install with `pepe plugin install`, review the scan, and grant the tool to an
   agent (CLI, dashboard, or by chat with `enable_tool`).

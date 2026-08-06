---
title: Plugins
description: Extend Pepe with your own tools and channels by installing plugins with their own settings.
---

A plugin is a file you install to teach Pepe something new, with no rebuild and no
restart: drop it in and it works. Most plugins do one of two things: add a **tool**
the model can call, or add a **channel provider** (a new webhook-based messaging
platform). This page covers those two shapes in depth, the most common by far, plus
shorter looks at the rest below.

A plugin can also take other shapes: a **persistent-connection channel** (one that
needs a long-lived websocket, not just a webhook, see [Slots](/docs/slots)), an
**HTTP route of its own** (an OAuth callback, a custom endpoint, see below), a
**realtime audio provider** (duplex voice, see below), a **model protocol adapter**,
a **hook** (rewrites conversation content for real, chained and inline, see below),
a **policy** (vetoes a tool call, or a whole run, before it happens; a check that
couldn't run counts as a refusal, so it fails closed), or a **run observer** (watches
the loop from outside, read-only, the one shape that can't affect anything). A plugin
can also occupy a [**slot**](/docs/slots): memory search, web search, the sandbox a
shell command runs in, conversation compaction, or the entire reasoning loop.

Under the hood, every plugin is Elixir compiled at runtime from `~/.pepe/plugins/`,
and a module is matched against whichever shape(s) it implements.

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
| `deliver_blocks/3` | no | Renders structured content (see [Presentation blocks](#presentation-blocks) below) into the platform's own native UI. Omit it and the `send_presentation` tool still delivers, flattened to plain text through `deliver/3` instead. |

### Presentation blocks

A tool can send richer content than plain text (a table, a row of buttons) via the
`send_presentation` tool and the shared `Pepe.Presentation` block schema:

```
%{"type" => "text", "text" => "..."}
%{"type" => "table", "headers" => [...], "rows" => [[...], ...]}
%{"type" => "buttons", "buttons" => [%{"label" => "...", "value" => "..."}]}
```

Slack renders these as real Block Kit today (a `section` per text/table block, an
`actions` block of real buttons). A provider that hasn't added `deliver_blocks/3` yet
still gets the content: `Pepe.Presentation.to_text/1` flattens it to readable plain text,
sent through the provider's ordinary `deliver/3`. So a tool that sends blocks works on
every channel immediately, richly only where a provider has bothered to render them.

## The PluginRoute behaviour - a plugin's own HTTP route

`Pepe.Webhooks.Provider`'s inbound event contract is fixed - one shape, for chat
platforms. `Pepe.PluginRoute` is for anything that needs its own: an OAuth redirect
callback that must land on Pepe's own public domain, a custom REST/RPC endpoint.

```elixir
@callback route_prefix() :: String.t()
@callback call(conn :: Plug.Conn.t(), path :: [String.t()]) :: Plug.Conn.t()
```

`call/2` gets the raw `Plug.Conn` (already past the endpoint's own body-parsing) and
the path segments after your own prefix - full control, the same as any hand-written
Plug, since Pepe can't anticipate every shape a plugin's own protocol needs. A crashing
`call/2` answers `500`, never takes the request process (or anything else) down with it.

**Building one, step by step:**

1. Write a module implementing `route_prefix/0` and `call/2`:

   ```elixir
   defmodule MyPlugin.OAuthCallback do
     @behaviour Pepe.PluginRoute

     @impl true
     def route_prefix, do: "weather_oauth"

     @impl true
     def call(conn, _path) do
       # handle the provider's redirect, exchange the code, etc.
       Plug.Conn.send_resp(conn, 200, "connected")
     end
   end
   ```

2. Save it as `~/.pepe/plugins/weather_oauth.exs` and install it:
   `pepe plugin install ~/.pepe/plugins/weather_oauth.exs`.
3. **Enable the route explicitly** - claiming a prefix in code exposes nothing on its
   own, a **second, deliberate** opt-in is required, because a route (unlike a tool)
   answers any inbound request, not one the agent's own model decided to make:

   ```bash
   pepe plugin route list                 # every installed route-claiming plugin, enabled or not
   pepe plugin route enable weather_oauth # now reachable at /plugin-routes/weather_oauth/...
   pepe plugin route disable weather_oauth
   ```

4. Point whatever needs to reach it (an OAuth app's redirect URL, a webhook sender) at
   `https://your-domain/plugin-routes/weather_oauth/...` - the path segments after the
   prefix arrive in `call/2`'s second argument.

## The Realtime provider behaviour - duplex audio

None of Pepe's other extension points hold a continuous, two-way stream - a tool call,
a webhook, a slot occupant are all request/response or one-shot. `Pepe.Realtime.Provider`
is that primitive: a plugin owns everything about how inbound audio becomes an outbound
reply (a hosted realtime model, a streaming-STT-then-TTS pipeline), and a new WebSocket
channel carries the bytes.

```elixir
@callback name() :: String.t()
@callback start(agent :: map(), opts :: keyword(), sink :: pid()) :: {:ok, session :: term()} | {:error, term()}
@callback push_audio(session :: term(), chunk :: binary()) :: :ok | {:error, term()}
@callback push_text(session :: term(), text :: String.t()) :: :ok | {:error, term()}   # optional
@callback stop(session :: term()) :: :ok
```

A client joins `realtime:<agent_name>` (`realtime:default` for the default agent) with
`{"provider": "your_provider_name"}` in the join payload, then pushes binary chunks on
the `"audio"` event. `start/3`'s `sink` is the pid to send events back to for as long as
the session lives: `{:realtime_audio, chunk}`, `{:realtime_text, text}`, or
`{:realtime_stopped, reason}` if the provider ends the session on its own. Additive, not
a slot - several providers can be installed, and a client picks one by name per
connection; nothing needs enabling globally the way a `Pepe.PluginRoute` does. Pepe ships
no realtime provider itself - this is the extension point a plugin fills in.

**Building one, step by step:**

1. Write a module implementing `name/0`, `start/3`, `push_audio/2`, `stop/1`, and
   optionally `push_text/2`. The example below is an echo provider - it sends back
   whatever audio it receives, plus a caption for each chunk. Good enough to develop
   a client against before a real STT/TTS or hosted-model backend exists:

   ```elixir
   defmodule EchoRealtime do
     @behaviour Pepe.Realtime.Provider

     @impl true
     def name, do: "echo_realtime"

     @impl true
     def start(agent, _opts, sink) do
       send(sink, {:realtime_text, "session started for #{agent.name}"})
       {:ok, sink}
     end

     @impl true
     def push_audio(sink, chunk) do
       send(sink, {:realtime_text, "echoing #{byte_size(chunk)} bytes"})
       send(sink, {:realtime_audio, chunk})
       :ok
     end

     @impl true
     def push_text(sink, text) do
       send(sink, {:realtime_text, "echo: " <> text})
       :ok
     end

     @impl true
     def stop(_sink), do: :ok
   end
   ```

   `start/3`'s own `sink` argument doubles as the session term here, since this
   provider has no real connection/process of its own to track - a provider talking to
   an actual upstream (a hosted model, a local STT/TTS pipeline) would return something
   that identifies *that*, and use `sink` only for sending events back.

2. Save it as `~/.pepe/plugins/echo_realtime.exs` and install it:
   `pepe plugin install ~/.pepe/plugins/echo_realtime.exs`. Nothing else to enable - a
   realtime provider has no slot to pin and no route to turn on; it's live the moment
   it's installed, waiting for a client to ask for it by name.
3. From a client, join `realtime:<agent_name>` on the existing WebSocket
   (`/socket/websocket`) naming it in the payload:

   ```js
   let ws = new WebSocket("ws://localhost:4000/socket/websocket");
   ws.onmessage = (e) => console.log(JSON.parse(e.data));
   ws.onopen = () => {
     ws.send(JSON.stringify({
       topic: "realtime:default", event: "phx_join",
       payload: { provider: "echo_realtime" }, ref: 1
     }));
   };
   ```

4. Push binary chunks on the `"audio"` event once joined; `{:realtime_audio, ...}`/
   `{:realtime_text, ...}` events come back the same way any other channel push does.

## The Hook behaviour - real content mutation

A hook actually rewrites conversation content, inline, on the same synchronous path
`pii_redact`/`llm_redact`/`http_redact`/`presidio` already run on. This is how a
context-compaction or content-redaction plugin does real work - not to be confused with
a run observer (below), which can only watch.

```elixir
@callback name() :: String.t()
@callback stages() :: [:inbound | :outbound | :learn | :tool_result]
@callback run(stage, text :: String.t(), settings :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:ok, String.t(), [%{"fake" => String.t(), "real" => String.t()}]}
```

`:inbound` runs on the user's text before the model sees it; `:outbound` on the reply
before it's sent back; `:tool_result` on a tool's raw output before it joins the
conversation. An agent opts into hooks by name (`mix pepe agent add NAME --hooks
your_hook,pii_redact`) - a plugin hook is additive alongside the four built-ins, and a
built-in always wins a name clash, so pick a name distinct from `pii_redact`/`llm_redact`/
`http_redact`/`presidio`.

Hooks chain: with `--hooks bracket,exclaim`, `exclaim` sees `bracket`'s already-mutated
text, in order - sequential, each one seeing the previous one's output, not a fan-out.
Return the (possibly unchanged) text, and optionally a list of reversible-map entries
(`fake` a token, `real` the value it replaced) if you want them restored on the way back out.

**Fail-open, on purpose**: a hook that raises falls back to the input text rather than
breaking the turn. A hook mutates or redacts - it never blocks. To veto a call outright,
see `Pepe.Permissions.Policy` below, a deliberately different, narrower mechanism.

## The Policy behaviour - vetoing a tool call

A policy plugin can refuse a tool call before it runs, for a reason only your plugin
knows (a company rule, an external allowlist service, a rate limiter).

```elixir
@callback name() :: String.t()
@callback check(tool_name :: String.t(), args :: map(), ctx :: map()) ::
            :allow | :ask | {:ask, String.t()} | :deny | {:deny, String.t()}
```

Every installed policy is consulted on **every** gate call, for every agent it applies
to - not opt-in like a hook, since installing one only ever adds restriction. It's
checked before Pepe's own pre-approval logic, so a policy can veto even a call the
operator already marked `:always`-approved. Short of an outright refusal,
`:ask`/`{:ask, reason}` forces a human to look at a call that would otherwise have been
silently pre-approved - the reason shows up alongside the prompt. Most restrictive wins
across every installed policy: `:deny` beats `:ask` beats `:allow`.

"Applies to" can still be narrowed - by the operator, never by the agent itself, which
would defeat the point:

```bash
pepe policy list                                      # every installed policy + its scope
pepe policy scope no_bash_policy --agents support --projects acme
pepe policy scope no_bash_policy --clear              # back to applying everywhere
```

or directly in `config.json` (`"policy_scope"`, by policy name). No entry for a policy's
name means unscoped - every agent, the default and the original behavior. An agent can
never opt itself out; only whoever configures the scope decides where a given policy is
even consulted.

**Fail-closed - the one deliberate exception in this whole plugin system.** Every other
plugin surface in Pepe degrades to "as if it weren't installed" on a crash or timeout.
A policy plugin is the opposite: a `check/3` that raises, hangs past its timeout, or
returns anything other than an explicit `:allow` **denies the call**. A security check
that couldn't run is not the same thing as one that passed.

```elixir
defmodule MyPlugin.NoBashPolicy do
  @behaviour Pepe.Permissions.Policy

  @impl true
  def name, do: "no_bash_policy"

  @impl true
  def check("bash", _args, _ctx), do: {:deny, "bash is blocked on this instance"}
  def check(_name, _args, _ctx), do: :allow
end
```

Add an optional `check_run/3` to veto a whole run, before any tool call and before the
first model call - the only way to say "don't process this message at all" (a banned
sender, a message-level rate limit), since `check/3` never fires for a turn that never
calls a tool:

```elixir
@callback check_run(agent :: map(), first_message :: String.t(), ctx :: map()) ::
            :allow | :ask | {:ask, String.t()} | :deny | {:deny, String.t()}
```

## The RunObserver behaviour

A run observer watches an agent's turn from outside - useful for logging, metrics, or
alerting on what an agent does, without touching what it does. It is strictly
observation-only: it never sees the conversation's message history, can't block a turn,
and can't change anything about it, only find out what already happened, after the fact.

```elixir
@callback name() :: String.t()
@callback subscriptions() :: [atom()]
@callback handle_event(event :: atom(), payload :: term(), meta :: map()) :: any()
```

`subscriptions/0` names which event types you want - any of `:run_start`, `:tool_call`,
`:tool_denied`, `:tool_result`, `:assistant`, `:assistant_delta`, `:failover`,
`:output_cap`, `:usage`, `:inline`, `:done`, `:error`, `:run_end`. `handle_event/3` is
called once per event you subscribed to, in the order the turn produced them. `payload`
is the event tuple itself (e.g. `{:tool_result, "web_search", "..."}`) - with one
exception: `:tool_call` arrives as `{:tool_call, name}`, without its arguments, since
those haven't been through redaction yet and can carry secrets.

A minimal example that logs every tool call and the final answer:

```elixir
defmodule MyPlugin.ToolLogger do
  @behaviour Pepe.Agent.RunObserver
  require Logger

  @impl true
  def name, do: "tool_logger"

  @impl true
  def subscriptions, do: [:tool_call, :done]

  @impl true
  def handle_event(:tool_call, {:tool_call, name}, _meta), do: Logger.info("tool called: #{name}")
  def handle_event(:done, {:done, content}, _meta), do: Logger.info("run finished: #{String.slice(content, 0, 80)}")
end
```

Dispatch is asynchronous and isolated: a hung or crashing observer never slows down or
breaks the conversation it's watching. One that fails 3 times in a row is disabled -
across every future run, not just the one that tripped it - so a broken observer never
keeps paying its own detection cost forever, and never spams your logs with the same
failure. There's nothing to grant an agent for this one - installed is enabled.

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
folder recursively for `.exs` files, compiles each once, and recompiles a file
only when it changes on disk. Drop a file in, it works with no restart; edit it,
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
one is a trust decision, the same as installing any other software on your
machine. Install only from a source you trust, and prefer pinning a specific
version or commit.

Before it's placed on disk, `Pepe.Skills.Sentinel` scans the code. It reads
the **structure** of the code (its parse tree), not just the raw text, so it
flags dangerous calls precisely:

- shelling out (`System.cmd`, `:os.cmd`),
- dynamic eval (`Code.eval_string`),
- unsafe deserialization (`:erlang.binary_to_term`),
- destructive filesystem calls (`File.rm_rf`),
- atom exhaustion (`String.to_atom`),
- reading the environment or secret paths (`~/.ssh`, the Pepe config),
- network access.

Because it reads the structure rather than the words, it catches the aliased
and Erlang forms of those calls too, and it does not trip over the same words
when they appear in a comment or a string. It never executes the code, and
returns one of three verdicts:

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

defmodule Pepe.ACP.Protocol do
  @moduledoc """
  The wire vocabulary of the Agent Client Protocol, with no IO and no state.

  ACP is how a code editor talks to an agent running as a local subprocess: JSON-RPC
  2.0, one message per line on stdin/stdout, the same shape LSP gave language servers.
  This module owns the *messages* - envelopes, the capability handshake, the
  translation between a `Pepe.Agent.Runtime` lifecycle event and an ACP
  `session/update`, and the mapping between ACP's four permission-option kinds and
  the decisions `Pepe.Permissions` actually understands. `Pepe.ACP.Server` owns the
  *conversation*; `Pepe.ACP.Stdio` owns the bytes.

  Kept separate for the same reason `Pepe.MCP.Protocol` is: the encoding is the part
  worth testing on its own, without a pipe or a subprocess in the way.

  ## What is implemented, and what is not

  This is the protocol's **core subset**, not all of it: the handshake, one session,
  a prompt turn streamed back as it happens, and a tool call that stops to ask a
  human. Deliberately absent, and advertised as absent in `initialize_result/0` so a
  client never has to guess:

    * `session/load`, `session/fork`, `session/resume`, `session/list` (`loadSession:
      false`). An ACP session here is a live `Pepe.Agent.Session`, born with
      `session/new` and gone when the editor disconnects.
    * `authenticate` (`authMethods: []`). Pepe authenticates to *model providers*,
      out of `~/.pepe/config.json`; there is nothing for an editor to log in to.
    * image, audio and embedded-resource prompt blocks (all three prompt capabilities
      `false`). `text` is the one block type every agent MUST accept, and
      `resource_link` is baseline too - both are handled; anything else is refused
      out loud rather than silently dropped on the floor.
    * the client-side file system and terminal methods (`fs/read_text_file`,
      `terminal/*`). Pepe's own `read_file`/`write_file`/`bash` tools already run on
      the same machine the editor does, so routing them back through the editor would
      buy nothing but a second way for them to disagree.
    * session modes, plans, and elicitation.
  """

  alias Pepe.Permissions
  alias Pepe.Permissions.Prompt

  # A single integer, bumped only for breaking changes. Version 1 is the current
  # stable one (version 2 exists upstream as an explicitly-gated unstable draft, and
  # is not what a released editor speaks).
  @protocol_version 1

  @doc "The ACP major version this agent speaks."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "What we tell a client we are. The version is Pepe's real one, not a literal."
  @spec agent_info() :: map()
  def agent_info do
    version =
      case :application.get_key(:pepe, :vsn) do
        {:ok, vsn} -> to_string(vsn)
        _ -> "0.0.0"
      end

    %{"name" => "pepe", "title" => "Pepe", "version" => version}
  end

  @doc """
  The `initialize` result: every capability we actually have, and nothing we don't.

  An omitted or false capability means UNSUPPORTED in ACP, which is the whole point
  of answering honestly here - a client that reads `loadSession: false` will never
  send `session/load`, so there is no half-working path to fall into.
  """
  @spec initialize_result() :: map()
  def initialize_result do
    %{
      "protocolVersion" => @protocol_version,
      "agentInfo" => agent_info(),
      "agentCapabilities" => %{
        "loadSession" => false,
        "promptCapabilities" => %{
          "image" => false,
          "audio" => false,
          "embeddedContext" => false
        }
      },
      "authMethods" => []
    }
  end

  ###
  ### JSON-RPC envelopes
  ###

  @doc "A JSON-RPC 2.0 request (we send these for `session/request_permission`)."
  @spec request(term(), String.t(), map()) :: map()
  def request(id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  @doc "A JSON-RPC 2.0 notification - no id, so no response is expected."
  @spec notification(String.t(), map()) :: map()
  def notification(method, params),
    do: %{"jsonrpc" => "2.0", "method" => method, "params" => params}

  @doc "A successful JSON-RPC 2.0 response."
  @spec response(term(), map()) :: map()
  def response(id, result),
    do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  @doc "A JSON-RPC 2.0 error response. `id` is `nil` when the request was unparseable."
  @spec error(term(), integer(), String.t()) :: map()
  def error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  @doc "Standard JSON-RPC error codes, by name."
  @spec error_code(:parse | :invalid_request | :method_not_found | :invalid_params | :internal) :: integer()
  def error_code(:parse), do: -32_700
  def error_code(:invalid_request), do: -32_600
  def error_code(:method_not_found), do: -32_601
  def error_code(:invalid_params), do: -32_602
  def error_code(:internal), do: -32_603

  @doc """
  Wrap a `session/update` payload in its notification envelope.

  The payload is the tagged variant (`%{"sessionUpdate" => "agent_message_chunk",
  ...}`); the envelope carries the session id beside it, not around it.
  """
  @spec session_update(String.t(), map()) :: map()
  def session_update(session_id, update),
    do: notification("session/update", %{"sessionId" => session_id, "update" => update})

  @doc "An `agent_message_chunk` update carrying one piece of assistant text."
  @spec message_chunk(String.t()) :: map()
  def message_chunk(text),
    do: %{"sessionUpdate" => "agent_message_chunk", "content" => text_block(text)}

  @doc "A `text` content block."
  @spec text_block(String.t()) :: map()
  def text_block(text), do: %{"type" => "text", "text" => text}

  ###
  ### prompt content
  ###

  @doc """
  Flatten a `session/prompt` content-block array into the one string Pepe's runtime
  takes, or say which block type we can't read.

  Only two variants are accepted, and that is not an oversight: `text` is the block
  every ACP agent MUST support, and `resource_link` is baseline too (it carries a URI,
  not bytes - the agent is expected to go read it, which is exactly what Pepe's own
  `read_file` does). Image, audio and embedded `resource` blocks are gated behind
  prompt capabilities this agent advertises as `false`, so a well-behaved client never
  sends them; a client that does gets an error instead of a prompt that quietly lost
  half of what the user attached.
  """
  @spec prompt_text([map()]) :: {:ok, String.t()} | {:error, String.t()}
  def prompt_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, acc} ->
      case block_text(block) do
        {:ok, text} -> {:cont, {:ok, [text | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, parts |> Enum.reverse() |> Enum.join("\n")}
      {:error, _} = error -> error
    end
  end

  def prompt_text(_other), do: {:error, "`prompt` must be an array of content blocks"}

  defp block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: {:ok, text}

  # A mention of something the user pointed at in their editor. Rendered the way a
  # person would type it, with the URI kept intact so the agent can act on it.
  defp block_text(%{"type" => "resource_link", "uri" => uri} = block) when is_binary(uri) do
    case block["name"] do
      name when is_binary(name) and name != "" -> {:ok, "@#{name} (#{uri})"}
      _ -> {:ok, "@#{uri}"}
    end
  end

  defp block_text(%{"type" => type}) when is_binary(type),
    do: {:error, "this agent does not accept `#{type}` content blocks (see the prompt capabilities it reported in `initialize`)"}

  defp block_text(_other), do: {:error, "every entry in `prompt` must be a content block with a `type`"}

  ###
  ### tool calls
  ###

  # ACP's ToolKind is a UI hint - it picks the icon and the verb an editor shows. The
  # mapping is deliberately coarse and name-based: a tool Pepe doesn't recognize (a
  # plugin's, an MCP server's) lands on "other", which is the honest answer rather
  # than a guess dressed up as a classification.
  @kinds %{
    "read_file" => "read",
    "list_dir" => "read",
    "docs" => "read",
    "skill" => "read",
    "config_get" => "read",
    "session_search" => "read",
    "memory_search" => "read",
    "write_file" => "edit",
    "edit_file" => "edit",
    "move_file" => "move",
    "bash" => "execute",
    "run_script" => "execute",
    "run_code" => "execute",
    "fetch_url" => "fetch",
    "web_search" => "search"
  }

  @doc "The ACP `ToolKind` for one of Pepe's tools; `\"other\"` for anything unrecognized."
  @spec tool_kind(String.t()) :: String.t()
  def tool_kind(name), do: Map.get(@kinds, name, "other")

  @doc """
  A human-readable title for a tool call: the tool's name, plus the first sentence of
  its own description when it has one, so an internal name like `manage_pepe` isn't
  opaque in an editor's tool-call list.
  """
  @spec tool_title(String.t()) :: String.t()
  def tool_title(name) do
    case Pepe.Tools.summary(name) do
      "" -> name
      summary -> "#{name}: #{summary}"
    end
  end

  @doc "The `tool_call` update announcing a call that is about to happen."
  @spec tool_call(String.t(), String.t(), term()) :: map()
  def tool_call(tool_call_id, name, raw_args) do
    %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => tool_call_id,
      "title" => tool_title(name),
      "name" => name,
      "kind" => tool_kind(name),
      "status" => "pending",
      "rawInput" => Permissions.decode(raw_args)
    }
  end

  @doc """
  The `tool_call_update` closing a call out. `status` is `\"completed\"` or
  `\"failed\"` - a refused call is a failed one, not a finished one.
  """
  @spec tool_call_update(String.t(), String.t(), String.t()) :: map()
  def tool_call_update(tool_call_id, status, output) do
    %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => tool_call_id,
      "status" => status,
      "content" => [%{"type" => "content", "content" => text_block(output)}]
    }
  end

  ###
  ### permissions
  ###

  # ACP offers a client four option kinds to render; Pepe's gate understands seven
  # decisions. The kind is only a display hint (which button looks like the safe one),
  # so several Pepe decisions legitimately share one: `:this_run`, `:session_any`,
  # `:session_bypass` and `:always` are all "allow, and remember it" at different
  # widths, and the width is what the *label* says. The optionId carries the real
  # decision, so nothing is lost in the round trip.
  @option_kinds %{
    once: "allow_once",
    this_run: "allow_always",
    session: "allow_always",
    session_any: "allow_always",
    session_bypass: "allow_always",
    always: "allow_always",
    deny: "reject_once"
  }

  @doc "The ACP `PermissionOptionKind` display hint for one of Pepe's decisions."
  @spec option_kind(Permissions.decision()) :: String.t()
  def option_kind(decision), do: Map.get(@option_kinds, decision, "reject_once")

  @doc """
  The options a `session/request_permission` offers, drawn from
  `Pepe.Permissions.Prompt` so an editor shows exactly the same choices, in the same
  order, under the same wording as Telegram's buttons and the CLI's menu.

  The `optionId` is `Prompt.token/1`, which `Prompt.from_token/1` reads back - an
  unknown one becomes `:deny`, so a client that invents an id gets the safe answer
  rather than an atom leak.
  """
  @spec permission_options([Permissions.decision()], boolean()) :: [map()]
  def permission_options(decisions, tainted?) do
    Enum.map(decisions, fn decision ->
      %{
        "optionId" => Prompt.token(decision),
        "name" => Prompt.label(decision, tainted?),
        "kind" => option_kind(decision)
      }
    end)
  end

  @doc """
  The `toolCall` a permission request is about. ACP wants a `ToolCallUpdate` here, so
  the editor can show the call it is asking about; `rawInput` is the load-bearing
  field, because "may I run bash?" is a different question from "may I run `rm -rf`?"
  and only the second one is answerable.

  `notes` (why this is being asked at all - the run took in outside content, or a
  policy plugin escalated it) rides in `_meta`, ACP's sanctioned extension point.
  Pepe's own surfaces render those notes in full; an editor that ignores `_meta`
  still gets the signal, because `Prompt.label/2` already bakes it into the option
  labels themselves.
  """
  @spec permission_tool_call(String.t(), String.t(), term(), map()) :: map()
  def permission_tool_call(tool_call_id, name, raw_args, notes) do
    call = %{
      "toolCallId" => tool_call_id,
      "title" => tool_title(name),
      "name" => name,
      "kind" => tool_kind(name),
      "status" => "pending",
      "rawInput" => Permissions.decode(raw_args)
    }

    if notes == %{}, do: call, else: Map.put(call, "_meta", %{"pepe" => notes})
  end

  @doc """
  Read a client's answer to `session/request_permission` back into a decision the gate
  understands.

  A `cancelled` outcome is not a refusal: the question was withdrawn before anyone
  looked at it. It comes back as a deny carrying
  `Pepe.Permissions.cancelled_reason/0`, so the model is told "nobody answered" rather
  than "the user said no" - two different facts that call for two different next moves.
  """
  @spec decision_from_outcome(map()) :: Permissions.decision()
  def decision_from_outcome(%{"outcome" => %{"outcome" => "selected", "optionId" => id}}) when is_binary(id),
    do: Prompt.from_token(id)

  def decision_from_outcome(%{"outcome" => %{"outcome" => "cancelled"}}),
    do: {:deny, Permissions.cancelled_reason()}

  def decision_from_outcome(_other), do: :deny
end

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

  The handshake, sessions that outlive the connection (`session/new`, `session/list`,
  `session/load`, `session/resume`, `session/fork`, see `Pepe.ACP.Sessions`), a prompt
  turn streamed back as it happens, and a tool call that stops to ask a human. An ACP
  session is a `Pepe.Agent.Session` keyed `acp:<id>` whose history is saved on disk, so
  closing the editor no longer ends the conversation. Authentication methods report
  whether Pepe has a usable model configuration and how to finish setup. Prompt
  capabilities are advertised per agent:

    * a prompt capability the connection can't honestly promise (`image` only for an
      agent whose model has vision, `audio` only with a transcription route). Every
      block type is *read* (see `Pepe.ACP.Content`); a block that can't be used is
      reported out loud, never silently dropped.
    * the client-side file system and terminal methods (`fs/read_text_file`,
      `terminal/*`). Pepe's own `read_file`/`write_file`/`bash` tools already run on
      the same machine the editor does, so routing them back through the editor would
      buy nothing but a second way for them to disagree.
    * elicitation.

  Beyond the core, `Pepe.ACP.Updates` and `Pepe.ACP.Commands` add the plan panel,
  the context meter, slash commands and session modes; those are described where they
  are built.
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
  @spec initialize_result(String.t() | nil, map()) :: map()
  def initialize_result(
        agent_name \\ nil,
        prompt_capabilities \\ %{"image" => false, "audio" => false, "embeddedContext" => false}
      ) do
    %{
      "protocolVersion" => @protocol_version,
      "agentInfo" => agent_info(),
      "agentCapabilities" => %{
        "loadSession" => true,
        # An empty object per capability is the whole declaration: presence means "supported".
        "sessionCapabilities" => %{"list" => %{}, "resume" => %{}, "fork" => %{}},
        "promptCapabilities" => prompt_capabilities,
        # Editor-supplied MCP servers: the remote transports that work (Pepe.ACP.Mcp).
        "mcpCapabilities" => Pepe.ACP.Mcp.capabilities()
      },
      "authMethods" => Pepe.ACP.Auth.methods(agent_name)
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

  @doc "A `user_message_chunk` update: something the person said, replayed on `session/load`."
  @spec user_message_chunk(String.t()) :: map()
  def user_message_chunk(text),
    do: %{"sessionUpdate" => "user_message_chunk", "content" => text_block(text)}

  @doc """
  A `session_info_update`: the session's title and/or last-activity time changed. A field
  that is left out means "unchanged" in ACP, so only what is known is sent.
  """
  @spec session_info_update(keyword()) :: map()
  def session_info_update(fields) do
    Enum.reduce(fields, %{"sessionUpdate" => "session_info_update"}, fn
      {:title, title}, acc when is_binary(title) -> Map.put(acc, "title", title)
      {:updated_at, at}, acc when is_binary(at) -> Map.put(acc, "updatedAt", at)
      _other, acc -> acc
    end)
  end

  @doc "One entry of a `session/list` result."
  @spec session_info(String.t(), String.t(), String.t(), String.t() | nil) :: map()
  def session_info(session_id, cwd, title, updated_at) do
    %{"sessionId" => session_id, "cwd" => cwd, "title" => title}
    |> then(&if(is_binary(updated_at), do: Map.put(&1, "updatedAt", updated_at), else: &1))
  end

  @doc "A `text` content block."
  @spec text_block(String.t()) :: map()
  def text_block(text), do: %{"type" => "text", "text" => text}

  ###
  ### tool calls
  ###

  # Kind, title, locations and result content live in `Pepe.ACP.ToolView`, so how a call
  # is *shown* can be tested without a pipe. This module only assembles the messages.

  @doc "The ACP `ToolKind` for one of Pepe's tools; `\"other\"` for anything unrecognized."
  @spec tool_kind(String.t()) :: String.t()
  defdelegate tool_kind(name), to: Pepe.ACP.ToolView, as: :kind

  @doc """
  The `tool_call` update announcing a call that is about to happen.

  Options: `:cwd` (the editor's project, so the files a call touches are reported as
  absolute locations) and `:diff` (a `Pepe.ACP.Edits` proposal, shown as a diff before
  anything is written). The tool's own name rides in `_meta`, not in a top-level key the
  protocol has no place for.
  """
  @spec tool_call(String.t(), String.t(), term(), keyword()) :: map()
  def tool_call(tool_call_id, name, raw_args, opts \\ []) do
    args = Permissions.decode(raw_args)

    %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => tool_call_id,
      "title" => Pepe.ACP.ToolView.title(name, args),
      "kind" => Pepe.ACP.ToolView.kind(name),
      "status" => "pending",
      "rawInput" => args,
      "_meta" => %{"pepe" => %{"tool" => name}}
    }
    |> put_locations(name, args, opts[:cwd])
    |> put_diff(opts[:diff])
  end

  @doc """
  The `tool_call_update` closing a call out. `status` is `\"completed\"` or
  `\"failed\"` - a refused call is a failed one, not a finished one. A call that changed
  a file keeps its diff (`:diff`) beside the output, so the editor still shows what was
  done once the call is over.
  """
  @spec tool_call_update(String.t(), String.t(), term(), keyword()) :: map()
  def tool_call_update(tool_call_id, status, output, opts \\ []) do
    content =
      case opts[:diff] do
        nil -> Pepe.ACP.ToolView.result_content(output)
        diff -> [Pepe.ACP.Edits.diff_content(diff) | Pepe.ACP.ToolView.result_content(output)]
      end

    %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => tool_call_id,
      "status" => status,
      "content" => content
    }
  end

  defp put_locations(call, name, args, cwd) do
    case Pepe.ACP.ToolView.locations(name, args, cwd) do
      [] -> call
      locations -> Map.put(call, "locations", locations)
    end
  end

  defp put_diff(call, nil), do: call
  defp put_diff(call, diff), do: Map.put(call, "content", [Pepe.ACP.Edits.diff_content(diff)])

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
  @spec permission_tool_call(String.t(), String.t(), term(), map(), keyword()) :: map()
  def permission_tool_call(tool_call_id, name, raw_args, notes, opts \\ []) do
    args = Permissions.decode(raw_args)

    %{
      "toolCallId" => tool_call_id,
      "title" => Pepe.ACP.ToolView.title(name, args),
      "kind" => Pepe.ACP.ToolView.kind(name),
      "status" => "pending",
      "rawInput" => args,
      "_meta" => %{"pepe" => Map.put(notes, "tool", name)}
    }
    |> put_locations(name, args, opts[:cwd])
    |> put_diff(opts[:diff])
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

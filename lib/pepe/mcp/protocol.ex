defmodule Pepe.MCP.Protocol do
  @moduledoc """
  The parts of MCP that are the same whatever the bytes travel over.

  A transport differs only in how a JSON-RPC message gets to the server and back: a pipe
  (`Pepe.MCP.Client`), one POST per message (`Pepe.MCP.Client.Http`), or a POST out and a
  held-open event stream back (`Pepe.MCP.Client.Sse`). The messages themselves - the
  `initialize` handshake, `tools/list`, `tools/call`, and how a result turns into the text an
  agent sees - are identical, and live here so the three transports cannot drift into
  disagreeing about the protocol they all claim to speak.
  """

  @protocol "2025-06-18"

  @doc "The MCP protocol version this client negotiates."
  def protocol_version, do: @protocol

  @doc """
  What we tell a server we are. The version is Pepe's real one rather than a literal, so a
  server's logs and any version-conditional behavior see the client that is actually calling.
  """
  def client_info do
    version =
      case :application.get_key(:pepe, :vsn) do
        {:ok, vsn} -> to_string(vsn)
        _ -> "0.0.0"
      end

    %{"name" => "pepe", "version" => version}
  end

  @doc "Params for the `initialize` request."
  def initialize_params do
    %{
      "protocolVersion" => @protocol,
      "capabilities" => %{},
      "clientInfo" => client_info()
    }
  end

  @doc "A JSON-RPC 2.0 request as a plain map."
  def request(id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  @doc "A JSON-RPC 2.0 notification (no id, so no response is expected)."
  def notification(method, params),
    do: %{"jsonrpc" => "2.0", "method" => method, "params" => params}

  @doc "The tools array out of a `tools/list` response, or `[]`."
  def tools_from(response), do: get_in(response, ["result", "tools"]) || []

  @doc """
  Flatten an MCP tool result into `{:ok, text}` / `{:error, reason}`.

  `isError: true` is a **failed** tool call that the transport nonetheless delivered
  successfully - the server is reporting, in-band, that the tool itself did not work (a bad
  argument, a 404 upstream). Reading only the JSON-RPC envelope, as this did before remote
  transports arrived, hands that text back as `{:ok, ...}` and the agent goes on believing the
  call worked. The distinction costs one key and is the difference between an agent retrying
  and an agent confidently building on a failure.
  """
  def tool_result(%{"result" => %{"isError" => true} = result}),
    do: {:error, content_text(result["content"]) || "the tool reported an error"}

  def tool_result(%{"result" => %{"content" => content}}) when is_list(content),
    do: {:ok, content_text(content) || ""}

  def tool_result(%{"result" => result}), do: {:ok, Jason.encode!(result)}
  def tool_result(%{"error" => error}), do: {:error, error}
  def tool_result(_), do: {:error, :bad_response}

  defp content_text(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => t} -> t
      other -> Jason.encode!(other)
    end)
  end

  defp content_text(_), do: nil

  @doc """
  Interpolate `${ENV_VAR}` references so a secret lives in the environment and only its name
  is written to `config.json`. An unresolved reference becomes `""` rather than the literal
  `${VAR}`, so a missing token fails as "unauthorized" instead of being sent to the server as
  the word it was supposed to stand for.
  """
  def interp(value) when is_binary(value), do: Pepe.Config.interpolate(value) || ""
  def interp(value), do: value

  @doc """
  `interp/1` for a value that belongs to `spec`, except that a spec marked `literal: true`
  is left exactly as written.

  A configured server's values come from the operator's own `config.json`, where `${VAR}`,
  `exec:` and `file:` are the documented way to keep a secret out of the file. A server an
  editor hands over for one session is a different provenance - project-level editor
  settings can come out of a cloned repository - and there those same strings are not a
  request to read Pepe's environment, run a resolver command or read a local file and send
  the result to whatever that server is. They are just text.
  """
  def interp(value, %{literal: true}), do: value
  def interp(value, _spec), do: interp(value)
end

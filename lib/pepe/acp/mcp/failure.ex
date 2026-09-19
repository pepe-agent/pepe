defmodule Pepe.ACP.Mcp.Failure do
  @moduledoc """
  Words for why an editor-supplied MCP server did not start, to show the person in the
  editor's chat.

  The reason a transport reports is an Erlang term, and it can carry things that must not be
  read back into a conversation: a URL with a token in its query string, the body an
  unhappy server answered with, an argument list. So this never inspects a reason it does
  not recognise, quotes nothing from an argument or a header, and clips what a *server* said
  about itself to a short single line.
  """

  @doc "A short sentence fragment (`\"could not be reached\"`) for a startup `reason`."
  @spec describe(term()) :: String.t()
  def describe({:mcp_start_failed, {:not_found, command}}) when is_binary(command),
    do: "could not be started: the command `#{clip(command)}` was not found on PATH"

  def describe({:mcp_start_failed, :no_command}), do: "could not be started: it has no command to run"
  def describe({:mcp_start_failed, _other}), do: "could not be started"

  def describe({:mcp_handshake_failed, :timeout}), do: describe(:timeout)

  def describe({:mcp_handshake_failed, {:exit, status}}) when is_integer(status),
    do: "exited during the MCP handshake (status #{status})"

  def describe({:mcp_handshake_failed, %{"message" => message}}) when is_binary(message),
    do: "refused the MCP handshake: #{clip(message)}"

  def describe({:mcp_handshake_failed, _other}), do: "did not complete the MCP handshake"

  def describe(:timeout), do: "did not answer the MCP handshake in time"
  def describe({:mcp_unreachable, _}), do: "could not be reached"

  def describe({:mcp_unauthorized, _}),
    do: "answered 401 Unauthorized: add an `Authorization` header to the server's headers in your editor"

  def describe({:mcp_http_error, status, _body}) when is_integer(status), do: "answered HTTP #{status}"

  def describe({:mcp_not_streamable, status}) when is_integer(status),
    do: "is not an MCP endpoint (HTTP #{status})"

  def describe({:mcp_no_endpoint_event, _url}), do: "never announced an event-stream endpoint"
  def describe({:mcp_tools_failed, _}), do: "connected but could not list its tools"
  def describe({:exception, name}) when is_binary(name), do: "could not be started (#{clip(name)})"
  def describe(_unknown), do: "could not be started"

  @doc "`http://host:port` of a URL and nothing else: no path, query string or credentials."
  @spec host_label(String.t()) :: String.t()
  def host_label(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        "#{scheme}://#{host}#{if port, do: ":#{port}"}"

      _ ->
        "(invalid address)"
    end
  end

  defp clip(text) do
    text
    |> String.replace(~r/[[:cntrl:]]+/u, " ")
    |> String.trim()
    |> String.slice(0, 160)
  end
end

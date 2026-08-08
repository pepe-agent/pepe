defmodule Pepe.MCP.Transport do
  @moduledoc """
  What every MCP transport has to provide, and how one is chosen for a server spec.

  `Pepe.MCP` holds pids, not knowledge of how each one talks: it starts a transport, keeps it
  in the registry, and asks it for tools or a call. Which module that is comes from the spec
  and nothing else - a `:command` is a local process, a `:url` is a remote server:

    * `Pepe.MCP.Client` - stdio, an MCP server spawned as a child process.
    * `Pepe.MCP.Client.Http` - Streamable HTTP (spec revision 2025-03-26), one POST per
      message. What a remote server published today speaks.
    * `Pepe.MCP.Client.Sse` - the older HTTP+SSE pair (revision 2024-11-05), kept because a
      server that has not migrated still answers only this.

  Remote specs default to `transport: "auto"`, which tries Streamable HTTP and falls back to
  HTTP+SSE. The fallback is not decoration: the two are told apart only by how the server
  answers, and guessing wrong looks to an operator exactly like a broken URL.
  """

  @doc "Start a transport for a server spec, with the usual GenServer opts."
  @callback start_link(spec :: map(), opts :: keyword()) :: GenServer.on_start()

  @doc "The tools the server advertises."
  @callback list_tools(pid()) :: [map()]

  @doc "Call one tool by its server-side name."
  @callback call_tool(pid(), String.t(), map() | nil) :: {:ok, String.t()} | {:error, term()}

  alias Pepe.MCP.Client

  @choices ~w(auto streamable sse)

  @doc """
  Every value a remote spec's `transport` may hold, default first.

  The set exists so a UI can offer it without keeping a second copy of it in sync:
  `for_spec/1` below is the only place that turns one of these into a module.
  """
  @spec choices() :: [String.t()]
  def choices, do: @choices

  @doc """
  The transport module a spec asks for, or `{:error, reason}` when it asks for nothing
  recognisable (neither a command to run nor a URL to reach).
  """
  @spec for_spec(map()) :: {:ok, module()} | {:error, term()}
  def for_spec(%{url: url} = spec) when is_binary(url) and url != "" do
    case Map.get(spec, :transport) do
      "sse" -> {:ok, Client.Sse}
      "streamable" -> {:ok, Client.Http}
      # "auto" and anything unset: Streamable HTTP, which falls back to SSE itself.
      _ -> {:ok, Client.Http}
    end
  end

  def for_spec(%{command: command}) when is_binary(command) and command != "",
    do: {:ok, Client}

  def for_spec(_), do: {:error, :no_transport}

  @doc "Is this a remote (HTTP) server spec?"
  def remote?(spec), do: is_binary(spec[:url]) and spec[:url] != ""
end

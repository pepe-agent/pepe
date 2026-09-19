defmodule Pepe.ACP.Mcp.Descriptor do
  @moduledoc """
  Turns the `mcpServers` an editor sends with `session/new` into server specs
  `Pepe.MCP` can start - or into a reason, per server, why one cannot be used.

  Three shapes arrive (Agent Client Protocol schema): a **stdio** server, a local command
  (`name`, `command`, `args`, `env` as a list of `{name, value}`); an **http** server
  (`type: "http"`, `name`, `url`, `headers` as a list of `{name, value}`); and an **sse**
  server (`type: "sse"`, same fields). Everything here is validation and translation.
  Nothing is started, and nothing is written anywhere.

  ## What a spec produced here guarantees

    * `literal: true`. Values are text, never references: `${VAR}`, `exec:` and `file:` are
      how an *operator* keeps a secret out of `config.json`, and honoring them for a value
      that arrived from an editor (project-level editor settings can come out of a cloned
      repository) would let it read Pepe's environment, run a resolver command or read a
      file and hand the result to whatever the server is. See `Pepe.MCP.Protocol.interp/2`.
    * `name: nil`. A stored OAuth token is looked up by server name; an editor-supplied
      server must never be handed the token of a configured server that shares its name.
    * A namespaced tool prefix (`mcp__editor_<name>__`) that is refused outright when it
      would equal a configured server's name, so an editor cannot speak as one of the
      operator's own servers - the prefix is also what a standing `auto_approve` grant
      matches on.
    * Bounded: at most eight servers, and limits on argument, variable and header counts and
      sizes.
  """

  alias Pepe.Config

  @max_servers 8
  @max_args 64
  @max_env 64
  @max_headers 32
  @max_value 8192
  @max_name 128
  @name_length 20

  @env_name ~r/^[A-Za-z_][A-Za-z0-9_]{0,127}$/
  @header_name ~r/^[A-Za-z0-9!#$%&'*+.^_`|~-]{1,128}$/

  @type server :: %{
          name: String.t(),
          ns: String.t(),
          transport: :stdio | :http | :sse,
          spec: map()
        }

  @doc "The most servers one session may attach."
  @spec max_servers() :: pos_integer()
  def max_servers, do: @max_servers

  @doc """
  Validate and translate `descriptors`. Returns `{accepted, rejected}`: `accepted` in the
  order sent, each with the `ns` (server namespace, `editor_<name>`) its tools are
  published under; `rejected` as `{display_name, reason}` with a reason fit to show a
  person. `opts[:cwd]` is the directory a stdio server starts in.
  """
  @spec normalize(term(), keyword()) :: {[server()], [{String.t(), String.t()}]}
  def normalize(descriptors, opts \\ []) when is_list(descriptors) do
    {valid, invalid} =
      descriptors
      |> Enum.map(&one(&1, opts[:cwd]))
      |> Enum.split_with(&match?({:ok, _}, &1))

    {kept, over} = valid |> Enum.map(fn {:ok, s} -> s end) |> Enum.split(@max_servers)

    rejected =
      Enum.map(invalid, fn {:error, name, reason} -> {name, reason} end) ++
        Enum.map(over, &{&1.name, "too many servers (at most #{@max_servers} per session)"})

    {accepted, clashes} = namespace(kept)
    {accepted, rejected ++ clashes}
  end

  ###
  ### one descriptor
  ###

  defp one(desc, cwd) when is_map(desc) do
    with {:ok, name} <- fetch_name(desc),
         {:ok, transport} <- transport(desc, name),
         {:ok, spec} <- build(transport, desc, name, cwd) do
      {:ok, %{name: name, ns: nil, transport: transport, spec: spec}}
    end
  end

  defp one(_desc, _cwd), do: {:error, "(unnamed)", "not an MCP server description"}

  defp fetch_name(%{"name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, "(unnamed)", "the server has no name"}
      trimmed when byte_size(trimmed) > @max_name -> {:error, clip(trimmed), "the name is too long"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_name(_desc), do: {:error, "(unnamed)", "the server has no name"}

  defp transport(%{"type" => "http"}, _name), do: {:ok, :http}
  defp transport(%{"type" => "sse"}, _name), do: {:ok, :sse}
  defp transport(%{"type" => "stdio"}, _name), do: {:ok, :stdio}
  defp transport(%{"type" => other}, name), do: {:error, name, "unsupported transport `#{clip(to_string_safe(other))}`"}
  defp transport(%{"url" => _}, _name), do: {:ok, :http}
  defp transport(%{"command" => _}, _name), do: {:ok, :stdio}
  defp transport(_desc, name), do: {:error, name, "it has neither a `command` nor a `url`"}

  ###
  ### stdio
  ###

  defp build(:stdio, desc, name, cwd), do: stdio(desc, name, cwd)
  defp build(transport, desc, name, _cwd), do: remote(transport, desc, name)

  defp stdio(desc, name, cwd) do
    with {:ok, command} <- command(desc["command"], name),
         {:ok, args} <- args(desc["args"], name),
         {:ok, env} <- env(desc["env"], name) do
      {:ok, %{name: nil, command: command, args: args, env: env, cwd: cwd, literal: true}}
    end
  end

  # A bare name is resolved on PATH and an absolute path is used as is. A *relative* path
  # (`./server`, `bin/server`) is resolved against Pepe's own working directory, which is
  # not the editor's project - accepting it would run something other than what was meant.
  defp command(cmd, name) when is_binary(cmd) do
    cond do
      cmd == "" or String.contains?(cmd, <<0>>) -> {:error, name, "the `command` is empty"}
      byte_size(cmd) > 4096 -> {:error, name, "the `command` is too long"}
      Path.type(cmd) == :absolute -> {:ok, cmd}
      String.contains?(cmd, ["/", "\\"]) -> {:error, name, "the `command` must be an absolute path or a bare name found on PATH"}
      true -> {:ok, cmd}
    end
  end

  defp command(_cmd, name), do: {:error, name, "the server has no `command`"}

  defp args(nil, _name), do: {:ok, []}

  defp args(list, name) when is_list(list) do
    cond do
      length(list) > @max_args -> {:error, name, "too many arguments (at most #{@max_args})"}
      Enum.all?(list, &text?/1) -> {:ok, list}
      true -> {:error, name, "`args` must be a list of strings"}
    end
  end

  defp args(_other, name), do: {:error, name, "`args` must be a list of strings"}

  defp env(nil, _name), do: {:ok, %{}}

  defp env(list, name) when is_list(list) do
    cond do
      length(list) > @max_env -> {:error, name, "too many environment variables (at most #{@max_env})"}
      true -> pairs(list, name, @env_name, "environment variable")
    end
  end

  defp env(map, name) when is_map(map), do: env(Enum.map(map, fn {k, v} -> %{"name" => k, "value" => v} end), name)
  defp env(_other, name), do: {:error, name, "`env` must be a list of name/value pairs"}

  ###
  ### http / sse
  ###

  defp remote(transport, desc, name) when transport in [:http, :sse] do
    with {:ok, url} <- url(desc["url"], name),
         {:ok, headers} <- headers(desc["headers"], name) do
      {:ok,
       %{
         name: nil,
         url: url,
         headers: headers,
         # "auto" tries Streamable HTTP and falls back to the legacy pair, so a server
         # declared `http` that only speaks the older protocol still connects.
         transport: if(transport == :sse, do: "sse", else: "auto"),
         oauth: %{},
         literal: true
       }}
    end
  end

  defp url(url, name) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if byte_size(url) <= 4096, do: {:ok, url}, else: {:error, name, "the `url` is too long"}

      _ ->
        {:error, name, "the `url` must be an http or https address"}
    end
  end

  defp url(_url, name), do: {:error, name, "the server has no `url`"}

  defp headers(nil, _name), do: {:ok, %{}}

  defp headers(list, name) when is_list(list) do
    if length(list) > @max_headers,
      do: {:error, name, "too many headers (at most #{@max_headers})"},
      else: pairs(list, name, @header_name, "header")
  end

  defp headers(map, name) when is_map(map),
    do: headers(Enum.map(map, fn {k, v} -> %{"name" => k, "value" => v} end), name)

  defp headers(_other, name), do: {:error, name, "`headers` must be a list of name/value pairs"}

  ###
  ### shared
  ###

  # A header value with a line break would split the request (header injection); an
  # environment variable may legitimately hold one.
  defp pairs(list, name, name_pattern, what) do
    Enum.reduce_while(list, {:ok, %{}}, fn
      %{"name" => key, "value" => value}, {:ok, acc} when is_binary(key) and is_binary(value) ->
        cond do
          not Regex.match?(name_pattern, key) ->
            {:halt, {:error, name, "invalid #{what} name `#{clip(key)}`"}}

          not text?(value) or (what == "header" and String.contains?(value, ["\r", "\n"])) ->
            {:halt, {:error, name, "invalid value for #{what} `#{key}`"}}

          true ->
            {:cont, {:ok, Map.put(acc, key, value)}}
        end

      _other, _acc ->
        {:halt, {:error, name, "each #{what} must have a `name` and a `value`"}}
    end)
  end

  defp text?(value), do: is_binary(value) and byte_size(value) <= @max_value and not String.contains?(value, <<0>>)

  # Give each accepted server the namespace its tools are published under. The name a
  # person wrote is kept for messages; the namespace is a safe, short, unique slug.
  defp namespace(servers) do
    {accepted, clashes, _used} =
      Enum.reduce(servers, {[], [], MapSet.new()}, fn server, {acc, bad, used} ->
        ns = unique("editor_" <> slug(server.name), used)

        if Config.mcp_server(ns) do
          {acc, [{server.name, "its tool namespace `#{ns}` is already taken by a server configured on this Pepe"} | bad], used}
        else
          {[%{server | ns: ns} | acc], bad, MapSet.put(used, ns)}
        end
      end)

    {Enum.reverse(accepted), Enum.reverse(clashes)}
  end

  defp unique(ns, used), do: unique(ns, used, ns, 2)

  defp unique(base, used, candidate, n) do
    if MapSet.member?(used, candidate), do: unique(base, used, "#{base}_#{n}", n + 1), else: candidate
  end

  # `__` separates the server from the tool inside a tool name, so a slug can never hold it.
  defp slug(name) do
    slug =
      name
      |> String.replace(~r/[^A-Za-z0-9_-]+/, "_")
      |> String.replace(~r/_{2,}/, "_")
      |> String.trim("_")
      |> String.slice(0, @name_length)
      |> String.trim("_")

    if slug == "", do: "server", else: slug
  end

  defp clip(text), do: text |> String.replace(~r/[[:cntrl:]]/u, " ") |> String.slice(0, 80)

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: inspect(value)
end

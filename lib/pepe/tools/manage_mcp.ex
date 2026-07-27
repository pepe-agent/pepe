defmodule Pepe.Tools.ManageMcp do
  @moduledoc """
  Let an agent connect and inspect **MCP (Model Context Protocol) servers** - external
  tool providers like Sentry or GitHub - from a conversation.

  A server is either **local** (a `command` spawned over stdio, e.g. `npx`) or **remote** (a
  `url` reached over HTTP). Remote is the newer half and the easier one to grant: nothing has
  to be installed on the box, so a hosted server needs only its URL and a credential.

  The typical flow (autonomous, no manual install because a local server is launched via
  `npx` on demand and a remote one runs somewhere else entirely):

    1. `add` a server with its command/args or its url/headers, putting any token in as a
       `${ENV_VAR}` reference so the secret never touches the chat or the config file.
    2. `tools` it to validate the connection **live** and see what it offers.
    3. Grant an agent the *read-only* subset by adding the specific tool names
       (e.g. `mcp__sentry__find_organizations`) to that agent's tools with
       `manage_agent` - leaving the mutating ones (`mcp__sentry__update_issue`) out.

  **Signing in with OAuth is not an action here**, and that is a decision rather than an
  omission. It needs a browser and a human at it, so an agent cannot complete it; what it
  could do is produce a link and ask someone to authorize it, which is the shape of a
  phishing message and would be one if the agent were ever talked into pointing it
  somewhere else. The operator runs `mix pepe mcp login NAME` (or clicks the button on the
  dashboard's MCP page) and the agent says so. `logout` *is* here: it only removes access,
  which is the direction that is safe to be wrong about.

  It's a risky tool (in the allowlist + through the permission gate).

  Secrets are expected as `${ENV_VAR}` references. A token pasted in raw is **not refused**,
  it is saved and reported: by the time we see it, it has already been typed into a chat, so
  it has been through a model provider and is in the transcript and the trace. Refusing the
  write would not un-leak it; it would only leave the person confused and the token no less
  compromised. So the server gets added, and the answer says what has to happen now - revoke
  it, reissue it, put the new one in the environment. `pepe doctor` says so too, for the ones
  nobody read. See `Pepe.Secrets`.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Config

  @impl true
  def name, do: "manage_mcp"

  @impl true
  def spec do
    function(
      "manage_mcp",
      """
      Connect and inspect MCP (Model Context Protocol) servers - external tool \
      providers. Put tokens as ${ENV_VAR} references, never raw. Actions:
      - add: register a server - needs `name` plus EITHER `url` (a remote server over \
        HTTP, with optional `headers` like {"Authorization": "Bearer ${MCP_TOKEN}"}) \
        OR `command` (e.g. "npx") with `args` (array, e.g. \
        ["-y","@sentry/mcp-server@latest","--access-token","${SENTRY_AUTH_TOKEN}"]) and \
        optional `env` (object of ${ENV} refs).
      - tools: connect to the server and list its tools live to validate - needs `name`. \
        Their agent-facing names are mcp__<name>__<tool>.
      - list: show configured servers and, for remote ones, what credential they have.
      - remove: delete a server - needs `name`.
      - logout: forget a remote server's stored OAuth grant - needs `name`.

      A remote server that answers 401 wants OAuth, which cannot be done from a chat (it \
      opens a browser). Say so and give the operator the command: mix pepe mcp login NAME.

      After adding, grant an agent only the READ tools via manage_agent (add_tool).
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ~w(add tools list remove logout)},
          "name" => %{"type" => "string", "description" => "The server name."},
          "command" => %{"type" => "string", "description" => "Local server: executable, e.g. \"npx\"."},
          "url" => %{
            "type" => "string",
            "description" => "Remote server: its MCP endpoint URL. Use instead of command."
          },
          "headers" => %{
            "type" => "object",
            "description" => "Remote server auth headers (values may be ${ENV_VAR})."
          },
          "transport" => %{
            "type" => "string",
            "enum" => ~w(auto streamable sse),
            "description" => "Remote server only. Leave unset: it negotiates. Pin it only if that fails."
          },
          "args" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Command args; put tokens as ${ENV_VAR}."
          },
          "env" => %{
            "type" => "object",
            "description" => "Extra env vars (values may be ${ENV_VAR})."
          }
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx) do
    if ctx[:agent], do: dispatch(action, args), else: {:error, "no calling agent in context"}
  end

  def run(_args, _ctx), do: {:error, "manage_mcp needs an `action`"}

  defp dispatch("list", _args), do: {:ok, render_list()}
  defp dispatch("add", args), do: add(args)
  defp dispatch("tools", %{"name" => name}), do: list_tools(name)
  defp dispatch("remove", %{"name" => name}), do: remove(name)
  defp dispatch("logout", %{"name" => name}), do: logout(name)
  defp dispatch(other, _args), do: {:error, "unknown or incomplete action: #{other}"}

  defp add(args) do
    with {:ok, name} <- fetch(args, "name"),
         {:ok, definition, secrets} <- definition(args) do
      Config.put_mcp_server(name, definition)

      saved = "MCP server #{name} saved. Run `tools` on it to validate, then grant an agent its read tools."

      # The env/headers map is where a token actually goes, and it used to be the one place
      # nobody looked: the old guard read the args array only, so
      # `env: {"GITHUB_TOKEN": "ghp_..."}` sailed through into config.json in the clear,
      # unmentioned. `headers` is the same hole on the remote side, so it is scanned too.
      {:ok, saved <> Pepe.Secrets.warning(secrets, "the MCP server #{name}")}
    end
  end

  # Remote (url) or local (command) - one or the other, never both, since the two are
  # different servers wearing one name and only one of them would ever be used.
  defp definition(%{"url" => url} = args) when is_binary(url) and url != "" do
    headers = args["headers"] || %{}

    {:ok, %{"url" => url, "headers" => headers, "transport" => args["transport"] || "auto"}, Pepe.Secrets.plaintext_in(headers)}
  end

  defp definition(args) do
    case fetch(args, "command") do
      {:ok, command} ->
        args_list = args["args"] || []
        env = args["env"] || %{}

        {:ok, %{"command" => command, "args" => args_list, "env" => env}, raw_secrets(args_list, env)}

      _ ->
        {:error, "a server needs either `url` (remote) or `command` (local)"}
    end
  end

  # A credential in the clear, wherever it was put: named in `env`, or sitting positionally in
  # `args` (`--token ghp_...`), where it has no key name to be recognised by.
  defp raw_secrets(args_list, env) do
    in_env = Pepe.Secrets.plaintext_in(env)

    in_args =
      args_list
      |> Enum.filter(&Pepe.Secrets.plaintext?/1)
      |> Enum.map(&{"args", &1})

    in_env ++ in_args
  end

  defp list_tools(name) do
    case Config.mcp_server(name) do
      nil ->
        {:error, "no MCP server named #{name}"}

      _ ->
        case Pepe.MCP.tools(name) do
          {:ok, tools} ->
            {:ok, "#{name} exposes (agent name -> description):\n\n" <> render_tools(name, tools)}

          {:error, reason} ->
            {:error, "couldn't reach #{name}: #{inspect(reason)}"}
        end
    end
  end

  # Signing IN is not here on purpose (see the moduledoc). Signing OUT is: it only ever
  # removes access, needs no browser, and is the thing someone asks for in a hurry.
  defp logout(name) do
    case Pepe.MCP.OAuth.credential(name) do
      nil ->
        {:ok, "#{name} had no stored OAuth grant - nothing to forget."}

      _ ->
        Pepe.MCP.OAuth.logout(name)
        Pepe.MCP.restart(name)
        {:ok, "Forgot the OAuth grant for #{name}. It will need `mix pepe mcp login #{name}` again."}
    end
  end

  defp remove(name) do
    case Config.mcp_server(name) do
      nil ->
        {:error, "no MCP server named #{name}"}

      _ ->
        Config.delete_mcp_server(name)
        {:ok, "MCP server #{name} removed."}
    end
  end

  ###
  ### helpers
  ###

  defp render_list do
    case Config.mcp_servers() do
      m when map_size(m) == 0 ->
        "No MCP servers configured."

      servers ->
        Enum.map_join(servers, "\n", &server_line/1)
    end
  end

  defp server_line({name, %{"url" => url} = cfg}) when is_binary(url),
    do: "• #{name}: #{url} (remote, auth: #{auth_state(name, cfg)})"

  defp server_line({name, cfg}),
    do: "• #{name}: #{cfg["command"]} #{Enum.join(cfg["args"] || [], " ")}"

  defp auth_state(name, cfg) do
    cond do
      map_size(cfg["headers"] || %{}) > 0 -> "a static key from a header"
      Pepe.MCP.OAuth.credential(name) -> "signed in with OAuth"
      true -> "NONE - a 401 from it means this, not a bad URL"
    end
  end

  defp render_tools(server, tools) do
    Enum.map_join(tools, "\n", fn t ->
      "• mcp__#{server}__#{t["name"]} - #{String.slice(to_string(t["description"]), 0, 100)}"
    end)
  end

  defp fetch(args, key) do
    case args[key] do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "#{key} is required"}
    end
  end
end

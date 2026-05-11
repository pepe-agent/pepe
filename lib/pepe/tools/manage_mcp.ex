defmodule Pepe.Tools.ManageMcp do
  @moduledoc """
  Let an agent connect and inspect **MCP (Model Context Protocol) servers** - external
  tool providers like Sentry or GitHub - from a conversation.

  The typical flow (autonomous, no manual install because the server is launched via
  `npx` on demand):

    1. `add` a server with its command/args, putting any token in as a `${ENV_VAR}`
       reference so the secret never touches the chat or the config file.
    2. `tools` it to validate the connection **live** and see what it offers.
    3. Grant an agent the *read-only* subset by adding the specific tool names
       (e.g. `mcp__sentry__find_organizations`) to that agent's tools with
       `manage_agent` - leaving the mutating ones (`mcp__sentry__update_issue`) out.

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
      - add: register a server - needs `name`, `command` (e.g. "npx"), `args` (array, \
        e.g. ["-y","@sentry/mcp-server@latest","--access-token","${SENTRY_AUTH_TOKEN}"]); \
        optional `env` (object of ${ENV} refs).
      - tools: launch the server and list its tools live to validate - needs `name`. \
        Their agent-facing names are mcp__<name>__<tool>.
      - list: show configured servers.
      - remove: delete a server - needs `name`.

      After adding, grant an agent only the READ tools via manage_agent (add_tool).
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ~w(add tools list remove)},
          "name" => %{"type" => "string", "description" => "The server name."},
          "command" => %{"type" => "string", "description" => "Executable, e.g. \"npx\"."},
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
  defp dispatch(other, _args), do: {:error, "unknown or incomplete action: #{other}"}

  defp add(args) do
    with {:ok, name} <- fetch(args, "name"),
         {:ok, command} <- fetch(args, "command") do
      args_list = args["args"] || []
      env = args["env"] || %{}

      Config.put_mcp_server(name, %{"command" => command, "args" => args_list, "env" => env})

      saved = "MCP server #{name} saved. Run `tools` on it to validate, then grant an agent its read tools."

      # The env map is where a token actually goes, and it used to be the one place nobody
      # looked: the old guard read the args array only, so `env: {"GITHUB_TOKEN": "ghp_..."}`
      # sailed through into config.json in the clear, unmentioned.
      {:ok, saved <> Pepe.Secrets.warning(raw_secrets(args_list, env), "the MCP server #{name}")}
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
        Enum.map_join(servers, "\n", fn {name, cfg} ->
          "• #{name}: #{cfg["command"]} #{Enum.join(cfg["args"] || [], " ")}"
        end)
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

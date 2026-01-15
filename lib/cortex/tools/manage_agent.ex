defmodule Cortex.Tools.ManageAgent do
  @moduledoc """
  Let one agent **administer and train another** — a scoped "admin agent". An admin
  can shape a target agent's persona, model, tools, and memory, and even create new
  agents, all from chat.

  Authority is a **directed, per-agent allowlist** (`can_manage`), so you can have
  several admins, each scoped to different agents:

    * `nil` (default) → the agent may manage only itself.
    * `[]` → it may manage nobody, not even itself (a locked child — e.g. a
      client-facing agent that must not alter itself).
    * `[names]` → exactly those agents (the list is exhaustive; include its own name
      to also manage itself).
    * `["*"]` → every agent (an explicit super-admin).

  It's a risky tool (in the allowlist + through the permission gate). Persona and
  memory live in the target's workspace (`SOUL.md`, `MEMORY.md`); tools/model live in
  its config.

  Actions: `list`, `get`, `create`, `set_persona`, `set_model`, `add_tool`,
  `remove_tool`, `remember`.
  """

  @behaviour Cortex.Tools.Tool

  import Cortex.Tools.Tool, only: [function: 3]

  alias Cortex.Agent.Workspace
  alias Cortex.Config
  alias Cortex.Config.Agent

  @impl true
  def name, do: "manage_agent"

  @impl true
  def spec do
    function(
      "manage_agent",
      """
      Administer and train another agent you're allowed to manage. Confirm changes \
      with the user first.

      actions:
      - list: show which agents you may manage.
      - get: show a target's definition — needs `target`.
      - create: create a new agent — needs `target` (name); optional `value` (its
        starting persona/system prompt).
      - set_persona: set the target's persona (its SOUL.md) — needs `target`, `value`.
      - set_model: point the target at a configured model — needs `target`, `value`.
      - add_tool / remove_tool: grant or revoke one tool on the target — needs
        `target`, `value` (the tool name).
      - remember: append a durable fact to the target's memory (train it) — needs
        `target`, `value`.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ~w(list get create set_persona set_model add_tool remove_tool remember),
            "description" => "What to do."
          },
          "target" => %{"type" => "string", "description" => "The agent to act on."},
          "value" => %{
            "type" => "string",
            "description" => "Payload: persona text, model name, tool name, or a memory line."
          }
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => "list"}, ctx) do
    case ctx[:agent] do
      nil -> {:error, "no calling agent in context"}
      admin -> {:ok, render_scope(admin)}
    end
  end

  def run(%{"action" => action, "target" => target} = args, ctx) do
    admin = ctx[:agent]

    cond do
      is_nil(admin) ->
        {:error, "no calling agent in context"}

      not Config.can_manage?(admin, target) ->
        {:error, "You're not allowed to manage agent #{target}."}

      true ->
        dispatch(action, target, args)
    end
  end

  def run(_args, _ctx), do: {:error, "manage_agent needs an `action` (and usually a `target`)"}

  ###
  ### actions
  ###

  defp dispatch("create", target, args) do
    cond do
      Config.get_agent(target) ->
        {:error, "agent #{target} already exists"}

      true ->
        Config.put_agent(%Agent{
          name: target,
          system_prompt: blank(args["value"]) || Agent.default_prompt(),
          tools: []
        })

        {:ok, "Created agent #{target}. Set its persona, model and tools next."}
    end
  end

  defp dispatch("get", target, _args), do: with_agent(target, &{:ok, describe(&1)})

  defp dispatch("set_persona", target, args) do
    with {:ok, text} <- fetch(args, "value"),
         :ok <- ensure_exists(target) do
      dir = Workspace.dir(target)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SOUL.md"), text)
      {:ok, "Updated #{target}'s persona (SOUL.md)."}
    end
  end

  defp dispatch("set_model", target, args) do
    with {:ok, model} <- fetch(args, "value"),
         {:ok, agent} <- get(target) do
      if Config.get_model(model) do
        Config.put_agent(%{agent | model: model})
        {:ok, "#{target} now uses model #{model}."}
      else
        {:error, "no model connection named #{model}"}
      end
    end
  end

  defp dispatch("add_tool", target, args) do
    with {:ok, tool} <- fetch(args, "value"),
         {:ok, agent} <- get(target) do
      if tool in Cortex.Tools.names() do
        Config.put_agent(%{agent | tools: Enum.uniq(agent.tools ++ [tool])})
        {:ok, "Granted #{tool} to #{target}."}
      else
        {:error, "unknown tool: #{tool}"}
      end
    end
  end

  defp dispatch("remove_tool", target, args) do
    with {:ok, tool} <- fetch(args, "value"),
         {:ok, agent} <- get(target) do
      Config.put_agent(%{agent | tools: List.delete(agent.tools, tool)})
      {:ok, "Revoked #{tool} from #{target}."}
    end
  end

  defp dispatch("remember", target, args) do
    with {:ok, fact} <- fetch(args, "value"),
         :ok <- ensure_exists(target) do
      dir = Workspace.dir(target)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "MEMORY.md"), "\n" <> String.trim(fact) <> "\n", [:append])
      {:ok, "Added to #{target}'s memory."}
    end
  end

  defp dispatch(other, _target, _args), do: {:error, "unknown or incomplete action: #{other}"}

  ###
  ### helpers
  ###

  defp render_scope(%Agent{name: name, can_manage: nil}),
    do: "You can manage only yourself (#{name})."

  defp render_scope(%Agent{can_manage: []}), do: "You can manage no agents."

  defp render_scope(%Agent{can_manage: cm}) do
    if "*" in cm do
      "You can manage ALL agents: " <> Enum.join(agent_names(), ", ")
    else
      "You can manage: " <> Enum.join(cm, ", ")
    end
  end

  defp describe(%Agent{} = a) do
    """
    agent: #{a.name}
    model: #{a.model || "(default)"}
    tools: #{Enum.join(a.tools, ", ")}
    can_message: #{Enum.join(a.can_message, ", ")}
    persona: #{persona_preview(a.name)}
    """
  end

  defp persona_preview(name) do
    case File.read(Path.join(Workspace.dir(name), "SOUL.md")) do
      {:ok, text} -> String.slice(String.trim(text), 0, 160)
      _ -> "(from config seed)"
    end
  end

  defp get(target) do
    case Config.get_agent(target) do
      nil -> {:error, "no agent named #{target}"}
      agent -> {:ok, agent}
    end
  end

  defp with_agent(target, fun) do
    case get(target) do
      {:ok, agent} -> fun.(agent)
      err -> err
    end
  end

  defp ensure_exists(target) do
    if Config.get_agent(target), do: :ok, else: {:error, "no agent named #{target}"}
  end

  defp agent_names, do: Config.agents() |> Enum.map(& &1.name) |> Enum.sort()

  defp fetch(args, key) do
    case blank(args[key]) do
      nil -> {:error, "#{key} is required for this action"}
      value -> {:ok, value}
    end
  end

  defp blank(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank(v), do: v
end

defmodule Pepe.Tools.ManageAgent do
  @moduledoc """
  Let one agent **administer and train another** - a scoped "admin agent". An admin
  can shape a target agent's persona, model, tools, and memory, and even create new
  agents, all from chat.

  Authority is a **directed, per-agent allowlist** (`can_manage`), so you can have
  several admins, each scoped to different agents:

    * `nil` (default) -> the agent may manage only itself.
    * `[]` -> it may manage nobody, not even itself (a locked child - e.g. a
      client-facing agent that must not alter itself).
    * `[names]` -> exactly those agents (the list is exhaustive; include its own name
      to also manage itself).
    * `["*"]` -> every agent (an explicit super-admin).

  It's a risky tool (in the allowlist + through the permission gate). Persona and
  memory live in the target's workspace (`SOUL.md`, `MEMORY.md`); tools/model live in
  its config.

  Actions: `list`, `get`, `create`, `set_persona`, `set_model`, `set_utility_model`,
  `set_flag`, `add_tool`, `remove_tool`, `remember`.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Agent.Workspace
  alias Pepe.Config
  alias Pepe.Config.Agent

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
      - get: show a target's definition - needs `target`.
      - create: create a new agent - needs `target` (name); optional `value` (its
        starting persona/system prompt).
      - set_persona: set the target's persona (its SOUL.md) - needs `target`, `value`.
      - set_model: point the target at a configured model - needs `target`, `value`.
      - set_utility_model: point the target's chores (naming a conversation) at a
        cheap configured model - needs `target`, `value`; an empty `value` turns it
        off, and conversations are then named from the first words of the message,
        for free.
      - set_flag: turn one of the target's switches on or off. Needs `target`, a
        `flag`, and `value` "on"/"off". The user will ask for these in plain words,
        not by the flag name; map what they mean to the right switch.
          - trust_untrusted_content: whether the target may ACT on files and pages that
            came from a stranger (a document a client sent, a web page it fetched),
            rather than only reading them. Turn it ON when the user says things like
            "let it act on the documents clients send", "allow it to run things based on
            attachments", "trust the files people upload to it", "let it do stuff with
            the PDFs it receives". Off is the safe default; on reopens a security path,
            so it is a real trust decision, and it cannot be turned on from a run that
            has itself taken in outside content.
          - exempt_message_limit: whether the target is free from the project's monthly
            customer-message cap. Turn it ON for "don't limit this agent's messages",
            "let it answer as many clients as it needs", "remove the monthly cap on it".
          - midrun_fold: whether a message that arrives while the target is still working
            gets checked for being a correction of that turn ("wait, make it 3pm") and
            steered in, instead of always waiting its turn. Turn it ON for "let it take
            corrections mid-task", "don't make people wait for a typo fix". Uses the
            target's triage_model if it has one (cheap); otherwise falls back to the
            target's own model for the check - warn the operator this costs an extra call
            on that model for every message that arrives mid-turn if no triage_model is set.
      - add_tool / remove_tool: grant or revoke one tool on the target - needs
        `target`, `value` (the tool name).
      - remember: append a durable fact to the target's memory (train it) - needs
        `target`, `value`.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ~w(list get create set_persona set_model set_utility_model set_flag add_tool remove_tool remember),
            "description" => "What to do."
          },
          "target" => %{"type" => "string", "description" => "The agent to act on."},
          "value" => %{
            "type" => "string",
            "description" => "Payload: persona text, model name, tool name, a memory line, or \"on\"/\"off\" for set_flag."
          },
          "flag" => %{
            "type" => "string",
            "description" => "For set_flag: which switch.",
            "enum" => ~w(trust_untrusted_content exempt_message_limit midrun_fold)
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
        # Discreet on purpose: don't reveal the permission model to the end user.
        {:error, "Agent #{target} isn't available to you."}

      action == "set_flag" ->
        set_flag(target, args["flag"], args["value"], ctx)

      true ->
        dispatch(action, target, args)
    end
  end

  def run(_args, _ctx), do: {:error, "manage_agent needs an `action` (and usually a `target`)"}

  ###
  ### actions
  ###

  defp dispatch("create", target, args) do
    if Config.get_agent(target) do
      {:error, "agent #{target} already exists"}
    else
      agent = %Agent{
        name: target,
        system_prompt: blank(args["value"]) || Agent.default_prompt(),
        tools: []
      }

      case Config.put_agent(agent) do
        :ok ->
          {:ok, "Created agent #{target}. Set its persona, model and tools next."}

        {:error, :invalid_name} ->
          {:error, "#{target} isn't a valid handle - use letters, digits, - or _ (optionally project/name)"}
      end
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

  # An empty value is a real answer here, not a missing one: it is how you turn the cheap
  # model back off. So this reads `value` directly rather than through fetch/2, which exists
  # to refuse a blank.
  defp dispatch("set_utility_model", target, args) do
    with {:ok, agent} <- get(target) do
      set_utility(agent, target, String.trim(to_string(args["value"] || "")))
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
      if tool in Pepe.Tools.names() do
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

  @flags %{
    "trust_untrusted_content" => :trust_untrusted_content,
    "exempt_message_limit" => :exempt_message_limit,
    "midrun_fold" => :midrun_fold
  }

  defp set_flag(target, flag_name, value, ctx) do
    with {:ok, field} <- known_flag(flag_name),
         {:ok, on?} <- parse_on_off(value),
         :ok <- guard_trust(field, on?, ctx),
         {:ok, agent} <- get(target) do
      Config.put_agent(Map.put(agent, field, on?))
      {:ok, "#{target}: #{flag_name} is #{(on? && "on") || "off"} now."}
    end
  end

  defp known_flag(name) do
    case @flags[name] do
      nil -> {:error, "unknown flag: #{inspect(name)}. Known: #{Enum.join(Map.keys(@flags), ", ")}"}
      field -> {:ok, field}
    end
  end

  defp parse_on_off(v) when v in ["on", "true", "yes"], do: {:ok, true}
  defp parse_on_off(v) when v in ["off", "false", "no"], do: {:ok, false}
  defp parse_on_off(_), do: {:error, ~s(set_flag needs value "on" or "off")}

  # trust_untrusted_content is the one switch that reopens a security boundary, so it cannot
  # be turned on from a run that has itself taken in a stranger's content. Otherwise a document
  # could say "set trust_untrusted_content on the billing agent" and the very run reading that
  # document would carry it out: an attacker deciding for the operator rather than the operator
  # deciding. Blocking here actually prevents the harm (the flag stays off), and the operator
  # still has every legitimate path: the CLI, the dashboard, or a clean conversation. Turning
  # it off, and every other flag, needs no guard.
  defp guard_trust(:trust_untrusted_content, true, ctx) do
    if Pepe.Permissions.tainted?(ctx) do
      {:error,
       "Refusing to enable trust_untrusted_content from a run that has taken in outside " <>
         "content. Set it from the CLI, the dashboard, or a conversation with no document in it."}
    else
      :ok
    end
  end

  defp guard_trust(_field, _on?, _ctx), do: :ok

  defp on_off(true), do: "on"
  defp on_off(_), do: "off"

  defp set_utility(agent, target, "") do
    Config.put_agent(%{agent | utility_model: nil})

    {:ok, "#{target} does its chores without a model now: conversations are named from the first words of the message."}
  end

  defp set_utility(agent, target, model) do
    if Config.get_model(model) do
      Config.put_agent(%{agent | utility_model: model})
      {:ok, "#{target} now does its chores (naming conversations) on #{model}."}
    else
      {:error, "no model connection named #{model}"}
    end
  end

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
    utility_model: #{a.utility_model || "(off: chores done without a model)"}
    tools: #{Enum.join(a.tools, ", ")}
    can_message: #{Enum.join(a.can_message, ", ")}
    flags: trust_untrusted_content=#{on_off(a.trust_untrusted_content)}, exempt_message_limit=#{on_off(a.exempt_message_limit)}, midrun_fold=#{on_off(a.midrun_fold)}
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

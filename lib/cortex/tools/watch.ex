defmodule Cortex.Tools.Watch do
  @moduledoc """
  Create and manage one-shot **watches** — "check X and notify me when it happens" —
  from a conversation.

  A watch re-checks a condition on a timer and messages the user **once** when it's
  met, then stops. It's durable (survives a restart and this session closing) and
  replies on the channel it was created from. Prefer a cheap `probe` (a shell command
  polled with no LLM) whenever the condition is scriptable; use an `agent` check only
  when it needs judgement.

  Like `schedule_task`, it's a gated tool — creating a watch goes through the human
  permission prompt unless pre-approved. Actions: `create`, `list`, `pause`,
  `resume`, `cancel`.
  """

  @behaviour Cortex.Tools.Tool

  import Cortex.Tools.Tool, only: [function: 3]

  alias Cortex.Config
  alias Cortex.Config.Watch
  alias Cortex.Watch.Delivery

  @max_active 50
  @min_interval_probe 30
  @min_interval_agent 300
  @default_interval 120
  @default_max_checks 720

  @impl true
  def name, do: "watch"

  @impl true
  def spec do
    function(
      "watch",
      """
      Create and manage one-shot "notify me when X" watches. A watch re-checks a \
      condition on a timer and messages you ONCE when it's met, then stops. It is \
      durable and replies on this same channel.

      Prefer a cheap probe when the condition is scriptable (a URL is up, a command \
      succeeds, a log contains a line) — it costs no tokens per check. Use an agent \
      check only when judging the condition needs the model.

      actions:
      - create: needs `description` and `trigger`.
        * trigger "probe": give `probe_command` (a shell command). Success = exit 0, \
          or set `probe_contains` to a string that must appear in its output.
        * trigger "agent": give `check_prompt` (a yes/no question the model answers \
          each check).
        on-fire (what to send): `notify` "template" with `message` (a fixed text, \
        default), or "agent" with `compose_prompt` (the model writes the message). \
        Optional `interval_s` (min 30 for probe, 300 for agent).
      - list: show active watches.
      - pause / resume / cancel: needs `id`.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ~w(create list pause resume cancel),
            "description" => "What to do."
          },
          "id" => %{"type" => "string", "description" => "Watch id (pause/resume/cancel)."},
          "description" => %{
            "type" => "string",
            "description" => "Short human summary of what you're watching for."
          },
          "trigger" => %{"type" => "string", "enum" => ~w(probe agent)},
          "probe_command" => %{
            "type" => "string",
            "description" => "Shell command to poll (probe trigger). e.g. \"curl -sf https://x\"."
          },
          "probe_contains" => %{
            "type" => "string",
            "description" => "Success if this string appears in the command output (optional)."
          },
          "check_prompt" => %{
            "type" => "string",
            "description" => "Yes/no question the model answers each check (agent trigger)."
          },
          "notify" => %{"type" => "string", "enum" => ~w(template agent)},
          "message" => %{"type" => "string", "description" => "Fixed text to send (template)."},
          "compose_prompt" => %{
            "type" => "string",
            "description" => "Instructions for the model to write the message (agent notify)."
          },
          "interval_s" => %{"type" => "integer", "description" => "Seconds between checks."}
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx) do
    if ctx[:agent], do: dispatch(action, args, ctx), else: {:error, "no calling agent in context"}
  end

  def run(_args, _ctx), do: {:error, "watch needs an `action`"}

  defp dispatch("create", args, ctx), do: create(args, ctx)
  defp dispatch("list", _args, _ctx), do: {:ok, render_list(active())}
  defp dispatch("pause", %{"id" => id}, _ctx), do: set_state(id, "paused", "paused")
  defp dispatch("resume", %{"id" => id}, _ctx), do: resume(id)
  defp dispatch("cancel", %{"id" => id}, _ctx), do: cancel(id)
  defp dispatch(action, _args, _ctx), do: {:error, "unknown or incomplete action: #{action}"}

  defp create(args, ctx) do
    with {:ok, desc} <- fetch(args, "description"),
         {:ok, trigger} <- build_trigger(args),
         {:ok, on_fire} <- build_on_fire(args, desc),
         :ok <- within_cap(),
         :ok <- not_duplicate(trigger) do
      watch = %Watch{
        id: unique_id(desc),
        description: desc,
        agent: ctx[:agent].name,
        trigger: trigger,
        on_fire: on_fire,
        origin: Delivery.origin_from_ctx(ctx),
        interval_s: interval(args, trigger),
        max_checks: @default_max_checks,
        state: "pending",
        created: System.system_time(:second)
      }

      Config.put_watch(watch)
      {:ok, "Watch created — I'll check and notify you once.\n\n" <> describe(watch)}
    end
  end

  defp build_trigger(%{"trigger" => "probe"} = args) do
    case blank_to_nil(args["probe_command"]) do
      nil ->
        {:error, "a probe trigger needs `probe_command`"}

      cmd ->
        success =
          if s = blank_to_nil(args["probe_contains"]), do: %{"contains" => s}, else: "exit_zero"

        {:ok, %{"type" => "probe", "command" => cmd, "success" => success}}
    end
  end

  defp build_trigger(%{"trigger" => "agent"} = args) do
    case blank_to_nil(args["check_prompt"]) do
      nil -> {:error, "an agent trigger needs `check_prompt`"}
      prompt -> {:ok, %{"type" => "agent", "prompt" => prompt}}
    end
  end

  defp build_trigger(_args), do: {:error, "`trigger` must be \"probe\" or \"agent\""}

  defp build_on_fire(%{"notify" => "agent"} = args, _desc) do
    case blank_to_nil(args["compose_prompt"]) do
      nil -> {:error, "an agent notify needs `compose_prompt`"}
      prompt -> {:ok, %{"type" => "agent", "prompt" => prompt}}
    end
  end

  defp build_on_fire(args, desc) do
    text = blank_to_nil(args["message"]) || "✅ #{desc}"
    {:ok, %{"type" => "template", "text" => text}}
  end

  defp interval(args, trigger) do
    min = if trigger["type"] == "agent", do: @min_interval_agent, else: @min_interval_probe
    max(args["interval_s"] || @default_interval, min)
  end

  defp within_cap do
    if length(active()) >= @max_active,
      do: {:error, "too many active watches (max #{@max_active}) — cancel some first"},
      else: :ok
  end

  # Refuse an identical live watch (same trigger) so we don't stack duplicates.
  defp not_duplicate(trigger) do
    if Enum.any?(active(), &(&1.trigger == trigger)),
      do: {:error, "a watch with that exact condition already exists"},
      else: :ok
  end

  defp resume(id) do
    case Config.get_watch(id) do
      nil ->
        {:error, "no watch with id #{id}"}

      w ->
        Config.put_watch(%{w | state: "pending", next_check: nil})
        {:ok, "Watch #{id} resumed."}
    end
  end

  defp cancel(id) do
    case Config.get_watch(id) do
      nil ->
        {:error, "no watch with id #{id}"}

      _ ->
        Config.delete_watch(id)
        {:ok, "Watch #{id} cancelled."}
    end
  end

  defp set_state(id, state, label) do
    case Config.get_watch(id) do
      nil ->
        {:error, "no watch with id #{id}"}

      w ->
        Config.put_watch(%{w | state: state})
        {:ok, "Watch #{id} #{label}."}
    end
  end

  # Active = anything not finished (pending/paused), newest-relevant first.
  defp active, do: Enum.filter(Config.watches(), &(&1.state in ["pending", "paused"]))

  defp render_list([]), do: "No active watches."
  defp render_list(watches), do: Enum.map_join(watches, "\n\n", &describe/1)

  defp describe(%Watch{} = w) do
    kind = w.trigger["type"] || "?"
    detail = w.trigger["command"] || w.trigger["prompt"] || ""

    [
      "• #{w.id} — #{w.description} (#{w.state})",
      "  trigger: #{kind} · every #{w.interval_s}s · #{String.slice(to_string(detail), 0, 60)}",
      "  checks: #{w.checks}/#{w.max_checks}",
      w.pending_delivery && "  ⏳ fired, waiting to deliver"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp fetch(args, key) do
    case blank_to_nil(args[key]) do
      nil -> {:error, "create needs `#{key}`"}
      value -> {:ok, value}
    end
  end

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(v), do: v

  defp unique_id(desc) do
    base =
      desc
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 30)
      |> then(fn s -> if s == "", do: "watch", else: s end)

    taken = Enum.map(Config.watches(), & &1.id)

    if base not in taken do
      base
    else
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = "#{base}-#{n}"
        if candidate not in taken, do: candidate
      end)
    end
  end
end

defmodule Pepe.Tools.ScheduleTask do
  @moduledoc """
  Create and manage the agent's own **scheduled tasks** (crons) from a conversation.

  A scheduled task runs a self-contained prompt on a recurring schedule, in a fresh
  session with no chat history - so when the agent creates one it must bake the full
  context into `prompt` (what to do, which data, the window), exactly the way the
  user described it in chat.

  An agent has this capability only when the tool is in its allowlist; it's a risky
  tool, so each call still goes through the permission gate (the human authorizes it)
  unless pre-approved.

  Actions: `create`, `list`, `remove`, `enable`, `disable`, `run` (force it now to
  preview), `history` (recent runs). Schedule is a standard 5-field cron expression
  in a named timezone; if the task doesn't name a timezone the config default is used.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Config
  alias Pepe.Config.Cron
  alias Pepe.Cron.Log

  @impl true
  def name, do: "schedule_task"

  @impl true
  def spec do
    function(
      "schedule_task",
      """
      Create and manage your own scheduled tasks (recurring jobs). A task runs on a \
      cron schedule in a FRESH session with no memory of this chat, so when you \
      `create` one you must write a self-contained `prompt` that includes everything \
      needed to do the job (context, what to check, the window). Confirm the details \
      with the user first (what, when, timezone, where to report).

      actions:
      - create: needs `name`, `prompt`, `schedule` (5-field cron, e.g. "0 8 * * *" \
        = 08:00 daily); optional `timezone` (IANA, e.g. "America/Sao_Paulo", \
        "Europe/Berlin" - omit to use the default), `model` (a configured model to \
        run it with), `deliver` ("telegram:<chat_id>" to report to a chat, "none" to \
        report nowhere; omit to report back to THIS chat).
      - list: show all scheduled tasks.
      - run: force a task now to preview it - needs `id`.
      - enable / disable / remove: needs `id`.
      - history: recent runs of a task - needs `id`.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ~w(create list run enable disable remove history),
            "description" => "What to do."
          },
          "id" => %{
            "type" => "string",
            "description" => "Task id (for run/enable/disable/remove/history)."
          },
          "name" => %{"type" => "string", "description" => "Human label for the task."},
          "prompt" => %{
            "type" => "string",
            "description" => "Self-contained instructions the task runs each time (no chat memory)."
          },
          "schedule" => %{
            "type" => "string",
            "description" => "5-field cron expression, e.g. \"0 8 * * *\" for 08:00 every day."
          },
          "timezone" => %{
            "type" => "string",
            "description" => "IANA timezone, e.g. \"America/Sao_Paulo\". Omit for the configured default."
          },
          "model" => %{
            "type" => "string",
            "description" => "Configured model to run the task with (optional)."
          },
          "deliver" => %{
            "type" => "string",
            "description" => "\"telegram:<chat_id>\", or \"none\". Omit to report back to this chat."
          }
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx) do
    if ctx[:agent], do: dispatch(action, args, ctx), else: {:error, "no calling agent in context"}
  end

  def run(_args, _ctx), do: {:error, "schedule_task needs an `action`"}

  defp dispatch("create", args, ctx), do: create(args, ctx)
  defp dispatch("list", _args, _ctx), do: {:ok, render_list(Config.crons())}
  defp dispatch("run", %{"id" => id}, _ctx), do: force_run(id)
  defp dispatch("enable", %{"id" => id}, _ctx), do: toggle(id, true)
  defp dispatch("disable", %{"id" => id}, _ctx), do: toggle(id, false)
  defp dispatch("remove", %{"id" => id}, _ctx), do: remove(id)
  defp dispatch("history", %{"id" => id}, _ctx), do: history(id)
  defp dispatch(action, _args, _ctx), do: {:error, "unknown or incomplete action: #{action}"}

  defp create(args, ctx) do
    with {:ok, name} <- fetch(args, "name"),
         {:ok, prompt} <- fetch(args, "prompt"),
         {:ok, schedule} <- fetch(args, "schedule"),
         :ok <- validate_schedule(schedule) do
      cron = %Cron{
        id: unique_id(name),
        name: name,
        agent: ctx[:agent].name,
        prompt: prompt,
        schedule: schedule,
        timezone: args["timezone"] || Config.default_timezone(),
        model: blank_to_nil(args["model"]),
        # An empty string is "omitted", not a real target - fall back to this chat.
        # (In Elixir `"" || x` keeps the "", so normalize blanks to nil first.)
        deliver: blank_to_nil(args["deliver"]) || default_deliver(ctx),
        enabled: true
      }

      Config.put_cron(cron)
      {:ok, "Scheduled task created.\n\n" <> describe(cron)}
    end
  end

  defp force_run(id) do
    case Config.get_cron(id) do
      nil ->
        {:error, "no scheduled task with id #{id}"}

      cron ->
        case Pepe.Cron.run(cron, :agent) do
          {:ok, output} -> {:ok, "Ran #{id} now:\n\n#{output}"}
          {:error, reason} -> {:error, "task #{id} failed: #{inspect(reason)}"}
        end
    end
  end

  defp toggle(id, enabled?) do
    case Config.get_cron(id) do
      nil ->
        {:error, "no scheduled task with id #{id}"}

      cron ->
        Config.put_cron(%{cron | enabled: enabled?})
        {:ok, "Task #{id} #{if enabled?, do: "enabled", else: "disabled"}."}
    end
  end

  defp remove(id) do
    case Config.get_cron(id) do
      nil ->
        {:error, "no scheduled task with id #{id}"}

      _cron ->
        Config.delete_cron(id)
        Log.delete(id)
        {:ok, "Task #{id} removed."}
    end
  end

  defp history(id) do
    case Log.tail(id, 10) do
      [] ->
        {:ok, "No runs recorded yet for #{id}."}

      entries ->
        {:ok, "Recent runs of #{id}:\n\n" <> Enum.map_join(entries, "\n", &format_entry/1)}
    end
  end

  ###
  ### helpers
  ###

  defp render_list([]), do: "No scheduled tasks."

  defp render_list(crons) do
    Enum.map_join(crons, "\n\n", &describe/1)
  end

  defp describe(%Cron{} = c) do
    next = Pepe.Cron.next_run(c)

    [
      "• #{c.id} - #{c.name}#{if c.enabled, do: "", else: " (disabled)"}",
      "  when: #{c.schedule} (#{c.timezone})",
      next && "  next: #{Calendar.strftime(next, "%Y-%m-%d %H:%M %Z")}",
      "  deliver: #{c.deliver}",
      c.model && "  model: #{c.model}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_entry(%{"at" => at, "ok" => ok?, "source" => src, "output" => out}) do
    "#{if ok?, do: "✅", else: "⚠️"} #{local_time(at)} (#{src})\n#{String.slice(to_string(out), 0, 300)}"
  end

  defp format_entry(entry), do: inspect(entry)

  # A run's timestamp in the configured timezone (not UTC).
  defp local_time(at) do
    with {:ok, utc} <- DateTime.from_unix(at),
         {:ok, dt} <- DateTime.shift_zone(utc, Config.default_timezone()) do
      Calendar.strftime(dt, "%Y-%m-%d %H:%M %Z")
    else
      _ -> to_string(at)
    end
  end

  # Report back to the originating chat by default, else nowhere.
  defp default_deliver(ctx) do
    case ctx[:session_key] do
      "telegram:" <> _ = key -> key
      _ -> "none"
    end
  end

  defp validate_schedule(schedule) do
    case Pepe.Cron.parse(schedule) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, "invalid cron expression #{inspect(schedule)}: #{msg}"}
    end
  end

  defp fetch(args, key) do
    case blank_to_nil(args[key]) do
      nil -> {:error, "create needs `#{key}`"}
      value -> {:ok, value}
    end
  end

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(v), do: v

  # A readable, unique id derived from the name (append -2, -3, ... on collision).
  defp unique_id(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> then(fn s -> if s == "", do: "task", else: s end)

    taken = Enum.map(Config.crons(), & &1.id)

    if base in taken do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(&suffixed_id(base, &1, taken))
    else
      base
    end
  end

  defp suffixed_id(base, n, taken) do
    candidate = "#{base}-#{n}"
    if candidate not in taken, do: candidate
  end
end

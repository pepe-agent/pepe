defmodule Pepe.Tools.SkillCurator do
  @moduledoc """
  Let a person look after their skill library from a conversation: see what the curator has
  in its care, run or pause it, change its settings, and undo or restore what it (or the
  background review) changed. The same operations as `mix pepe skill curator ...`.

  It is for a person who is present, never for the unattended review or curator runs: those
  hold `skill_manage` only (`Pepe.Skills.Reviewer`), and this tool refuses to run inside one
  anyway. It goes through the ordinary permission gate like `manage_skill`. Nothing here
  deletes: archiving is recoverable, and `restore` and `undo` bring things back.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Skills.Curator
  alias Pepe.Skills.Curator.Settings
  alias Pepe.Skills.Curator.State
  alias Pepe.Skills.Curator.Status
  alias Pepe.Skills.Ledger
  alias Pepe.Skills.Lifecycle
  alias Pepe.Skills.Manage

  @actions ~w(status usage archived log report run pause resume settings adopt release pin unpin restore undo)

  @impl true
  def name, do: "skill_curator"

  @impl true
  def spec do
    function(
      "skill_curator",
      """
      Look after the library of skills agents wrote for themselves (the "curator"). Skills a \
      person wrote, installed skills and pinned ones are never changed by it; it marks unused \
      agent-written skills stale, then archives them (recoverable), and can optionally merge \
      overlapping ones. Actions:
      - status: on/off, last and next run, what is in its care.
      - usage: every skill in its care with use counts and days idle.
      - archived: what was archived.
      - log: recent skill changes (newest first, with an id for `undo`); `name` narrows to one skill.
      - report: the text of the latest run report (or of `id`).
      - run: run now. `dry_run` (default true) only reports; `consolidate` adds the model pass \
        that merges overlapping skills. A real run snapshots the library first, and archives at \
        most a safety-capped number of skills at once unless `force`.
      - pause / resume: stop or restart the automatic runs.
      - settings: with no `key`, show them; with `key` and `value`, change one (enabled, \
        interval_hours, min_idle_hours, stale_after_days, archive_after_days, consolidate).
      - adopt / release: hand one of the person's skills to the curator, or take it back (`name`).
      - pin / unpin: a pinned skill is changed only by a person (`name`).
      - restore: bring an archived skill back (`name`).
      - undo: reverse one change by its `id` from `log`; refuses when the file changed since \
        unless `force`.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => @actions},
          "name" => %{"type" => "string", "description" => "Skill name (log, adopt, release, pin, unpin, restore)."},
          "id" => %{"type" => "string", "description" => "A ledger entry id (undo) or a report id (report)."},
          "dry_run" => %{"type" => "boolean", "description" => "run only: report without changing anything. Default true."},
          "consolidate" => %{"type" => "boolean", "description" => "run only: also run the model pass that merges overlapping skills."},
          "key" => %{"type" => "string", "description" => "settings: which setting."},
          "value" => %{"type" => "string", "description" => "settings: its new value."},
          "force" => %{
            "type" => "boolean",
            "description" => "undo: revert even if the file changed since. run: skip the per-run archive safety cap."
          }
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx) do
    cond do
      is_binary(ctx[:review_run]) -> {:error, "the curator cannot be driven from an unattended run"}
      action in @actions -> dispatch(action, args, actor(ctx))
      true -> {:error, "unknown action: #{action}"}
    end
  end

  def run(_args, _ctx), do: {:error, "skill_curator needs an `action`"}

  defp actor(ctx), do: "agent:" <> to_string(get_in(ctx, [:agent, Access.key(:name)]) || "chat")

  defp dispatch("status", _args, _actor), do: {:ok, Status.get() |> Status.lines() |> Enum.join("\n")}

  defp dispatch("usage", _args, _actor) do
    case Status.usage() do
      [] ->
        {:ok, "No skill is in the curator's care yet."}

      rows ->
        {:ok,
         Enum.map_join(
           rows,
           "\n",
           &"#{&1.name}: #{&1.state}, idle #{&1.idle_days}d, used #{&1.use_count}x, opened #{&1.view_count}x, edited #{&1.patch_count}x, failed #{&1.fail_count}x"
         )}
    end
  end

  defp dispatch("archived", _args, _actor) do
    case Lifecycle.archived() do
      [] -> {:ok, "No archived skills."}
      archived -> {:ok, Enum.map_join(archived, "\n", &"#{&1.name} (archived by #{&1.by})")}
    end
  end

  defp dispatch("log", args, _actor) do
    case Ledger.recent(30, args["name"]) do
      [] -> {:ok, "No skill changes recorded."}
      events -> {:ok, Enum.map_join(events, "\n", &Ledger.describe_with_id/1)}
    end
  end

  defp dispatch("report", args, _actor) do
    case Curator.read_report(args["id"]) do
      {:ok, text} -> {:ok, text}
      {:error, :not_found} -> {:error, "no such report"}
    end
  end

  defp dispatch("run", args, _actor) do
    dry? = Map.get(args, "dry_run", true) != false

    opts =
      [dry_run: dry?] ++
        if(args["consolidate"] == true, do: [consolidate: true], else: []) ++
        if(args["force"] == true, do: [force: true], else: [])

    {:ok, report} = Curator.run(opts)
    {:ok, run_message(report, dry?)}
  end

  defp dispatch("pause", _args, _actor) do
    State.set_paused(true)
    {:ok, "Curator paused: it will not start another run on its own. A run already in progress finishes; this does not stop it."}
  end

  defp dispatch("resume", _args, _actor) do
    State.set_paused(false)
    {:ok, "Curator resumed."}
  end

  defp dispatch("settings", %{"key" => key, "value" => value}, _actor) do
    case Settings.put(key, value) do
      :ok -> {:ok, "#{key} = #{Settings.get(key)}"}
      {:error, message} -> {:error, message}
    end
  end

  defp dispatch("settings", _args, _actor), do: {:ok, Enum.map_join(Settings.all(), "\n", fn {k, v} -> "#{k} = #{v}" end)}

  defp dispatch("adopt", %{"name" => name}, actor),
    do: result(Lifecycle.adopt(name, actor), "Adopted #{name}: background maintenance may now update it.")

  defp dispatch("release", %{"name" => name}, actor),
    do: result(Lifecycle.release(name, actor), "Released #{name}: it is the person's again.")

  defp dispatch("pin", %{"name" => name}, actor), do: result(Lifecycle.pin(name, true, actor), "Pinned #{name}.")
  defp dispatch("unpin", %{"name" => name}, actor), do: result(Lifecycle.pin(name, false, actor), "Unpinned #{name}.")

  defp dispatch("restore", %{"name" => name}, actor) do
    case Lifecycle.restore(name, actor) do
      {:ok, path} -> {:ok, "Restored #{name} (#{path})."}
      {:error, :exists} -> {:error, "a skill named #{name} already exists"}
      {:error, :not_archived} -> {:error, "no archived skill named #{name}"}
      {:error, reason} -> {:error, "could not restore #{name}: #{inspect(reason)}"}
    end
  end

  defp dispatch("undo", %{"id" => id} = args, actor) do
    case Manage.undo(id, actor, force: args["force"] == true) do
      {:ok, result} -> {:ok, result.message}
      {:error, message} -> {:error, message}
    end
  end

  defp dispatch(action, _args, _actor), do: {:error, "#{action} needs more arguments (see the tool description)"}

  defp result(:ok, message), do: {:ok, message}
  defp result({:error, message}, _), do: {:error, message}

  defp run_message(report, dry?) do
    lead = if dry?, do: "Dry run, nothing changed: ", else: "Done: "
    proposal = get_in(report, ["consolidation", "model_summary"])
    lead <> report["summary"] <> "\nReport: " <> report["report"] <> if(dry? and proposal, do: "\n\n" <> proposal, else: "")
  end
end

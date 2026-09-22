defmodule Pepe.Skills.Curator do
  @moduledoc """
  Keeps the library of agent-written skills from silting up, without anyone having to
  remember to.

  It does two things, and only ever to skills an agent wrote (`Pepe.Skills.Ownership`:
  managed, not pinned, not auto-loaded into a prompt). Skills a person wrote, installed
  skills, bundled skills and pinned ones are never touched, whatever their state.

    1. **A deterministic pass, no model.** Each skill moves between `active`, `stale` and
       `archived` on how long it has gone without being used, opened or changed
       (`Pepe.Skills.Stat.last_activity_at/1`): stale after `stale_after_days`, archived
       after `archive_after_days`, back to active if it is used again while stale. A skill
       that has never been used counts from when it was created, so a new one is never
       archived before it had a chance to be needed. Archiving moves the skill into
       `.archive/`; nothing is deleted, and `pepe skill restore` brings it back.
    2. **An optional model pass** (`consolidate`, off by default because it costs a run):
       `Pepe.Skills.Curator.Consolidate` asks a restricted agent to merge overlapping
       narrow skills into broader ones with support files, through `skill_manage`, so every
       step is owned, scanned and in the ledger.

  A run is taken only when the curator is enabled and not paused, the last run is older than
  `interval_hours`, and nothing has happened in any conversation for `min_idle_hours`. The
  first time it looks it only records the time and waits one interval, so installing or
  updating never rewrites a library on the spot. Before it changes anything it snapshots the
  whole skills directory (`Pepe.Skills.Backup`), and each run writes a report under
  `<PEPE_HOME>/skills/.curator/reports/`. `dry_run: true` reports what a run would do and
  changes nothing (the model pass then holds no write tool at all).

  It never deletes: removing an archived skill for good stays a person's explicit
  `pepe skill purge`.
  """

  import Ecto.Query, only: [from: 2]

  alias Pepe.Repo
  alias Pepe.Skills.Backup
  alias Pepe.Skills.Curator.Consolidate
  alias Pepe.Skills.Curator.Settings
  alias Pepe.Skills.Curator.State
  alias Pepe.Skills.Ledger
  alias Pepe.Skills.Lifecycle
  alias Pepe.Skills.Ownership
  alias Pepe.Skills.Snapshots
  alias Pepe.Skills.Stat
  alias Pepe.Skills.Stats
  alias Pepe.Usage.Run

  @actor "curator"
  @keep_reports 30
  @blob_days 90

  @type transition :: %{name: String.t(), from: String.t(), to: String.t(), reason: String.t()}

  ###
  ### what it may touch
  ###

  @doc "The skills the curator may act on: agent-written, unpinned, not auto-loaded, not archived."
  @spec candidates() :: [Stat.t()]
  def candidates do
    protected = MapSet.new(Pepe.Skills.Settings.auto_load())

    Stats.all()
    |> Map.values()
    |> Enum.filter(fn s ->
      s.managed and not s.pinned and s.state != "archived" and not MapSet.member?(protected, s.name) and
        Ownership.origin(s.name) == :agent
    end)
    |> Enum.sort_by(& &1.name)
  end

  ###
  ### the deterministic pass
  ###

  @doc "What the deterministic pass would do now, as a list of transitions."
  @spec plan(DateTime.t()) :: [transition()]
  def plan(now \\ DateTime.utc_now()) do
    stale_cutoff = DateTime.to_unix(now) - Settings.stale_after_days() * 86_400
    archive_cutoff = DateTime.to_unix(now) - Settings.archive_after_days() * 86_400

    for stat <- candidates(),
        transition = decide(stat, Stat.last_activity_at(stat), stale_cutoff, archive_cutoff),
        transition != nil,
        do: transition
  end

  defp decide(stat, anchor, _stale_cutoff, archive_cutoff) when anchor <= archive_cutoff,
    do: %{name: stat.name, from: stat.state, to: "archived", reason: "unused for #{Settings.archive_after_days()} days"}

  defp decide(%{state: "active"} = stat, anchor, stale_cutoff, _archive_cutoff) when anchor <= stale_cutoff,
    do: %{name: stat.name, from: "active", to: "stale", reason: "unused for #{Settings.stale_after_days()} days"}

  defp decide(%{state: "stale"} = stat, anchor, stale_cutoff, _archive_cutoff) when anchor > stale_cutoff,
    do: %{name: stat.name, from: "stale", to: "active", reason: "used again"}

  defp decide(_stat, _anchor, _stale_cutoff, _archive_cutoff), do: nil

  defp apply_transition(%{to: "archived"} = t) do
    case Lifecycle.archive(t.name, @actor, reason: t.reason) do
      {:ok, _} -> {:ok, t}
      {:error, reason} -> {:error, Map.put(t, :error, inspect(reason))}
    end
  end

  defp apply_transition(t) do
    Stats.set_state(t.name, t.to)
    Ledger.log(t.name, "state", @actor, %{from: t.from, to: t.to, reason: t.reason})
    {:ok, t}
  end

  ###
  ### a run
  ###

  @doc """
  Run the curator now. Options: `dry_run` (report only), `consolidate` (override the setting
  for this run), `now`. Returns `{:ok, report}`; the report is also written to disk.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) do
    dry? = opts[:dry_run] == true
    consolidate? = Keyword.get(opts, :consolidate, Settings.consolidate?())
    started = System.monotonic_time(:millisecond)
    plan = plan(opts[:now] || DateTime.utc_now())

    backup = if not dry? and (plan != [] or consolidate?), do: snapshot()
    {done, failed} = if dry?, do: {plan, []}, else: transitions(plan)
    consolidation = if consolidate?, do: Consolidate.run(dry_run: dry?)

    report =
      %{
        "at" => DateTime.to_iso8601(DateTime.utc_now()),
        "dry_run" => dry?,
        "checked" => length(candidates()),
        "transitions" => Enum.map(done, &stringify/1),
        "failed" => Enum.map(failed, &stringify/1),
        "consolidation" => consolidation,
        "backup" => backup,
        "duration_ms" => System.monotonic_time(:millisecond) - started
      }
      |> Map.put("summary", summary(done, failed, consolidation, dry?))

    path = write_report(report)
    report = Map.put(report, "report", path)
    unless dry?, do: finish(report)
    {:ok, report}
  end

  defp snapshot do
    case Backup.create("curator", @actor) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp transitions(plan) do
    results = Enum.map(plan, &apply_transition/1)
    {for({:ok, t} <- results, do: t), for({:error, t} <- results, do: t)}
  end

  defp finish(report) do
    Snapshots.prune(@blob_days)
    prune_reports()

    State.update(%{
      "last_run_at" => report["at"],
      "last_run_duration_ms" => report["duration_ms"],
      "last_run_summary" => report["summary"],
      "last_report" => report["report"],
      "run_count" => State.load()["run_count"] + 1
    })

    Ledger.log("*", "curator_run", @actor, %{summary: report["summary"], report: report["report"]})
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  @doc "One line describing a run's outcome (in the conditional for a dry run)."
  @spec summary([transition()], [transition()], map() | nil, boolean()) :: String.t()
  def summary(done, failed, consolidation, dry? \\ false) do
    counts = Enum.frequencies_by(done, & &1.to)
    stale = Map.get(counts, "stale", 0)
    archived = Map.get(counts, "archived", 0)
    active = Map.get(counts, "active", 0)

    base =
      if dry?,
        do: "would mark #{stale} stale, archive #{archived}, reactivate #{active}",
        else: "#{stale} marked stale, #{archived} archived, #{active} reactivated"

    base = if failed == [], do: base, else: base <> ", #{length(failed)} failed"
    if consolidation, do: base <> "; " <> (consolidation["summary"] || "consolidation ran"), else: base
  end

  ###
  ### when to run on its own
  ###

  @doc """
  Should the scheduler run the curator now? `:run`, or `{:skip, reason}` (`:disabled`,
  `:paused`, `:seeded` on the first look, `:not_due`, `:busy`).
  """
  @spec due(DateTime.t()) :: :run | {:skip, atom()}
  def due(now \\ DateTime.utc_now()) do
    cond do
      not Settings.enabled?() -> {:skip, :disabled}
      State.paused?() -> {:skip, :paused}
      State.last_run_at() == nil -> seed(now)
      DateTime.diff(now, State.last_run_at()) < Settings.interval_hours() * 3600 -> {:skip, :not_due}
      idle_seconds(now) < Settings.min_idle_hours() * 3600 -> {:skip, :busy}
      true -> :run
    end
  end

  defp seed(now) do
    State.update(%{
      "last_run_at" => DateTime.to_iso8601(now),
      "last_run_summary" => "first look: waiting one interval before the first run"
    })

    {:skip, :seeded}
  end

  @doc "Seconds since anything last ran in any conversation (`:infinity` when nothing ever has)."
  @spec idle_seconds(DateTime.t()) :: non_neg_integer() | :infinity
  def idle_seconds(now \\ DateTime.utc_now()) do
    case Stats.safe(fn -> Repo.one(from(r in Run, select: max(r.at))) end, nil) do
      nil -> :infinity
      at -> max(DateTime.to_unix(now) - at, 0)
    end
  end

  @doc "Run when `due/1` says so. Returns what it did."
  @spec maybe_run(keyword()) :: {:ran, map()} | {:skip, atom()}
  def maybe_run(opts \\ []) do
    case due(opts[:now] || DateTime.utc_now()) do
      :run ->
        {:ok, report} = run(opts)
        {:ran, report}

      skip ->
        skip
    end
  end

  ###
  ### reports
  ###

  defp write_report(report) do
    stamp = report["at"] |> String.replace(~r/[^0-9]/, "") |> String.slice(0, 14)
    suffix = if report["dry_run"], do: "-dry-run", else: ""
    base = Path.join(State.reports_dir(), stamp <> suffix)
    File.mkdir_p!(State.reports_dir())
    File.write!(base <> ".json", Jason.encode!(report, pretty: true))
    File.write!(base <> ".md", render(report))
    base <> ".md"
  end

  @doc "The ids of the saved run reports, newest first (a dry run's ends in `-dry-run`)."
  @spec reports() :: [String.t()]
  def reports do
    case File.ls(State.reports_dir()) do
      {:ok, files} ->
        files |> Enum.filter(&String.ends_with?(&1, ".md")) |> Enum.map(&String.replace_suffix(&1, ".md", "")) |> Enum.sort(:desc)

      _ ->
        []
    end
  end

  @doc "The text of a saved report (the newest when `id` is `nil`)."
  @spec read_report(String.t() | nil) :: {:ok, String.t()} | {:error, :not_found}
  def read_report(id \\ nil) do
    case id || List.first(reports()) do
      id when is_binary(id) ->
        if Regex.match?(~r/^[0-9]{1,14}(-dry-run)?$/, id), do: read_report_file(id), else: {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  defp read_report_file(id) do
    case File.read(Path.join(State.reports_dir(), id <> ".md")) do
      {:ok, text} -> {:ok, text}
      _ -> {:error, :not_found}
    end
  end

  defp prune_reports do
    case File.ls(State.reports_dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort(:desc)
        |> Enum.drop(@keep_reports)
        |> Enum.each(fn f ->
          File.rm(Path.join(State.reports_dir(), f))
          File.rm(Path.join(State.reports_dir(), String.replace_suffix(f, ".md", ".json")))
        end)

      _ ->
        :ok
    end
  end

  @doc "A run report as Markdown."
  @spec render(map()) :: String.t()
  def render(report) do
    title = if report["dry_run"], do: "Curator dry run (nothing was changed)", else: "Curator run"

    [
      "# #{title}",
      "",
      "- when: #{report["at"]}",
      "- skills checked: #{report["checked"]}",
      "- result: #{report["summary"]}",
      if(report["backup"], do: "- snapshot before changes: #{report["backup"]} (`pepe skill curator rollback #{report["backup"]}`)"),
      "",
      section("Moved between states", report["transitions"], &"- #{&1["name"]}: #{&1["from"]} to #{&1["to"]} (#{&1["reason"]})"),
      section("Could not be moved", report["failed"], &"- #{&1["name"]}: #{&1["error"]}"),
      consolidation_section(report["consolidation"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp section(_title, [], _line), do: nil
  defp section(_title, nil, _line), do: nil
  defp section(title, items, line), do: Enum.join(["## #{title}", "" | Enum.map(items, line)] ++ [""], "\n")

  defp consolidation_section(nil), do: nil

  defp consolidation_section(c) do
    lines =
      [
        "## Consolidation",
        "",
        c["summary"],
        "",
        Enum.map(c["archived"] || [], &"- archived #{&1["name"]}#{into(&1)}"),
        Enum.map(c["changed"] || [], &"- #{&1["action"]} #{&1["name"]}"),
        if(c["model_summary"], do: "\n#{c["model_summary"]}")
      ]

    lines |> List.flatten() |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  defp into(%{"into" => into}) when is_binary(into), do: " into #{into}"
  defp into(_), do: ""
end

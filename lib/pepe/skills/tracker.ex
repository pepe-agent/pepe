defmodule Pepe.Skills.Tracker do
  @moduledoc """
  What a background skill run has *read*, kept in memory for the length of the run.

  A background review or curator pass may not rewrite a skill from what it remembers or
  infers from a transcript: it has to have opened that exact file during the same run
  (`Pepe.Skills.Manage` refuses the write otherwise, and tells the run to read first). The
  `skill` tool and `read_file` leave a mark per run, keyed by a run id the runtime carries in
  the tool context as `:review_run`. Marks expire after a few hours, so a run that dies never
  leaves a permanent permission behind.

  The table is ETS owned by this process. Losing it (a restart) only means one more read
  before a write, which is why nothing here is persisted.
  """

  use GenServer

  @marks :pepe_skill_read_marks
  @mark_ttl_s 6 * 3600
  @sweep_ms 30 * 60 * 1000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Record that run `run` opened `name`'s file `file` (`nil` for the entry doc). A `nil` run
  is ignored: a foreground turn needs no marks, its writes go in front of a person.
  """
  @spec mark_read(String.t() | nil, String.t(), String.t() | nil) :: :ok
  def mark_read(nil, _name, _file), do: :ok

  def mark_read(run, name, file) when is_binary(run) and is_binary(name) do
    if :ets.whereis(@marks) != :undefined, do: :ets.insert(@marks, {{run, name, file}, now()})
    :ok
  end

  @doc """
  Record a read of an absolute `path` if it is inside the user skills directory: the entry
  doc of a skill (`nil` file) or one of its support files. Anything else is ignored, so
  `read_file` can call this for every read.
  """
  @spec mark_path(String.t() | nil, String.t()) :: :ok
  def mark_path(nil, _path), do: :ok

  def mark_path(run, path) when is_binary(run) and is_binary(path) do
    root = Path.expand(Pepe.Skills.user_dir())
    expanded = Path.expand(path)

    if String.starts_with?(expanded, root <> "/") do
      expanded |> Path.relative_to(root) |> Path.split() |> mark_parts(run)
    else
      :ok
    end
  end

  defp mark_parts([entry], run), do: mark_read(run, Path.rootname(entry, ".md"), nil)
  defp mark_parts([name, "SKILL.md"], run), do: mark_read(run, name, nil)
  defp mark_parts([name | rest], run), do: mark_read(run, name, Path.join(rest))
  defp mark_parts([], _run), do: :ok

  @doc "Did run `run` open this file? `false` for a `nil` run or when the table is gone."
  @spec read?(String.t() | nil, String.t(), String.t() | nil) :: boolean()
  def read?(nil, _name, _file), do: false

  def read?(run, name, file) do
    :ets.whereis(@marks) != :undefined and :ets.member(@marks, {run, name, file})
  end

  @doc "Drop every mark of a finished run."
  @spec forget_run(String.t()) :: :ok
  def forget_run(run) when is_binary(run) do
    if :ets.whereis(@marks) != :undefined, do: :ets.match_delete(@marks, {{run, :_, :_}, :_})
    :ok
  end

  ###
  ### server
  ###

  @impl true
  def init(_) do
    :ets.new(@marks, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now() - @mark_ttl_s
    :ets.select_delete(@marks, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp now, do: System.system_time(:second)
end

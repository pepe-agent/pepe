defmodule Pepe.Checkpoints.Report do
  @moduledoc """
  The words for a rewind, in one place, so Telegram, the console, the dashboard and the editor
  say exactly the same thing about the same result. Everything a person reads goes through
  gettext; the one note the *model* reads (`agent_note/2`) stays English, like every other
  `<system-reminder>` Pepe hands it.
  """

  use Gettext, backend: Pepe.Gettext

  @max_names 5

  @doc "Whether a restore report has nothing at all to say."
  @spec empty?(map() | nil) :: boolean()
  def empty?(nil), do: true

  def empty?(report) do
    Enum.all?([:restored, :removed, :skipped, :untracked], &(Map.get(report, &1, []) == [])) and
      Map.get(report, :unreached, 0) == 0 and Map.get(report, :expired, 0) == 0 and Map.get(report, :already, 0) == 0 and
      Map.get(report, :partial?, false) == false
  end

  @doc """
  The result of `Pepe.Agent.Session.rewind_to/4` (or `retry/3`) as text: the headline for
  what happened to the conversation, then one line per group of files. `opts`:
  `:requested` (how many turns were asked for), `:mode`, `:roots` (paths are shown relative
  to the first root that contains them).
  """
  @spec summary(map(), keyword()) :: String.t()
  def summary(%{dropped: dropped} = result, opts \\ []) do
    mode = Keyword.get(opts, :mode, :both)
    requested = Keyword.get(opts, :requested, dropped)
    opts = Keyword.put_new(opts, :roots, result[:roots] || [])

    ([headline(mode, dropped, requested, result[:files])] ++ file_lines(result[:files], opts) ++ kept_lines(result[:kept]))
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp headline(:files, _dropped, requested, files) do
    if (files && Map.get(files, :restored, []) == []) and Map.get(files, :removed, []) == [] do
      gettext("Nothing was put back. The conversation is unchanged.")
    else
      ngettext(
        "Put files back for the last %{count} turn. The conversation is unchanged.",
        "Put files back for the last %{count} turns. The conversation is unchanged.",
        requested,
        count: requested
      )
    end
  end

  defp headline(_mode, 0, _requested, _files), do: gettext("Nothing to rewind yet.")

  defp headline(_mode, dropped, requested, _files) when dropped < requested do
    ngettext(
      "Rewound %{count} turn. That was the whole conversation.",
      "Rewound %{count} turns. That was the whole conversation.",
      dropped,
      count: dropped
    )
  end

  defp headline(_mode, dropped, _requested, _files),
    do: ngettext("Rewound %{count} turn.", "Rewound %{count} turns.", dropped, count: dropped)

  @doc "The line that says a conversation-only rewind left `kept` files as they are (none when 0)."
  @spec kept_lines(term()) :: [String.t()]
  def kept_lines(kept) when is_integer(kept) and kept > 0 do
    [
      ngettext(
        "The %{count} file those turns changed was left as it is. Leave out \"chat\" to put files back too.",
        "The %{count} files those turns changed were left as they are. Leave out \"chat\" to put files back too.",
        kept,
        count: kept
      )
    ]
  end

  def kept_lines(_), do: []

  @doc "One line per group of files in a restore report, in the order a person cares about."
  @spec file_lines(map() | nil, keyword()) :: [String.t()]
  def file_lines(nil, _opts), do: []

  def file_lines(report, opts) do
    roots = Keyword.get(opts, :roots, [])
    name = &names(&1, roots)

    lines =
      List.flatten([
        group(report.restored, &put_back(&1, name.(&1))),
        group(report.removed, &removed(&1, name.(&1))),
        skipped_lines(report.skipped, name),
        untracked_lines(report.untracked, name),
        partial_line(report),
        turns_line(Map.get(report, :unreached, 0)),
        expired_line(Map.get(report, :expired, 0)),
        already_line(Map.get(report, :already, 0), report)
      ])

    if lines == [] and empty?(report), do: [gettext("No file changes were recorded for those turns.")], else: lines
  end

  defp group([], _fun), do: []
  defp group(paths, fun), do: [fun.(paths)]

  defp put_back(paths, files),
    do:
      ngettext("Put back %{count} file: %{files}.", "Put back %{count} files: %{files}.", length(paths), count: length(paths), files: files)

  defp removed(paths, files) do
    ngettext(
      "Removed %{count} file those turns created: %{files}.",
      "Removed %{count} files those turns created: %{files}.",
      length(paths),
      count: length(paths),
      files: files
    )
  end

  defp skipped_lines(skipped, name) do
    groups = Enum.group_by(skipped, &skip_kind(&1.reason), & &1.path)

    for {kind, paths} <- Enum.sort_by(groups, fn {kind, _} -> kind end) do
      skipped_line(kind, paths, name.(paths))
    end
  end

  defp skip_kind(:changed_since), do: :changed
  defp skip_kind(reason) when reason in [:too_large, :not_copied], do: :large
  defp skip_kind(:expired), do: :expired
  defp skip_kind(_), do: :other

  defp skipped_line(:changed, paths, files) do
    ngettext(
      "Left %{count} file alone because it changed afterwards: %{files}.",
      "Left %{count} files alone because they changed afterwards: %{files}.",
      length(paths),
      count: length(paths),
      files: files
    )
  end

  defp skipped_line(:large, paths, files) do
    ngettext(
      "No copy was kept of %{count} file (too large): %{files}.",
      "No copy was kept of %{count} files (too large): %{files}.",
      length(paths),
      count: length(paths),
      files: files
    )
  end

  defp skipped_line(:expired, paths, files) do
    ngettext(
      "The saved copy of %{count} file has expired: %{files}.",
      "The saved copy of %{count} files has expired: %{files}.",
      length(paths),
      count: length(paths),
      files: files
    )
  end

  defp skipped_line(:other, paths, files) do
    ngettext(
      "Could not put back %{count} file: %{files}.",
      "Could not put back %{count} files: %{files}.",
      length(paths),
      count: length(paths),
      files: files
    )
  end

  defp untracked_lines(untracked, name) do
    by = Enum.group_by(untracked, & &1.reason, & &1.path)

    for {reason, paths} <- Enum.sort_by(by, fn {reason, _} -> reason end) do
      untracked_line(reason, paths, name.(paths))
    end
  end

  defp untracked_line(:sensitive, paths, files) do
    ngettext(
      "%{count} file looks like a credential, so it is never copied and cannot be put back: %{files}.",
      "%{count} files look like credentials, so they are never copied and cannot be put back: %{files}.",
      length(paths),
      count: length(paths),
      files: files
    )
  end

  defp untracked_line(_reason, paths, files) do
    ngettext(
      "%{count} file it changed is outside the folders a rewind may touch: %{files}.",
      "%{count} files it changed are outside the folders a rewind may touch: %{files}.",
      length(paths),
      count: length(paths),
      files: files
    )
  end

  defp partial_line(%{partial?: true}),
    do: [gettext("A shell command changed more files than can be recorded, so some of its changes may not be put back.")]

  defp partial_line(_), do: []

  defp turns_line(n) when is_integer(n) and n > 0 do
    [
      ngettext(
        "%{count} of those turns is older than the file history, so its files were not touched.",
        "%{count} of those turns are older than the file history, so their files were not touched.",
        n,
        count: n
      )
    ]
  end

  defp turns_line(_), do: []

  defp expired_line(n) when is_integer(n) and n > 0 do
    [
      ngettext(
        "%{count} recorded change had already been cleaned up.",
        "%{count} recorded changes had already been cleaned up.",
        n,
        count: n
      )
    ]
  end

  defp expired_line(_), do: []

  # Only worth saying when it is the whole story: files were put back, then asked for again.
  defp already_line(n, report) when is_integer(n) and n > 0 do
    if report.restored == [] and report.removed == [] and report.skipped == [],
      do: [gettext("The files of those turns were already put back.")],
      else: []
  end

  defp already_line(_, _), do: []

  # First few names, shown relative to the root that holds them; the rest as "+N".
  defp names(paths, roots) do
    shown = paths |> Enum.take(@max_names) |> Enum.map(&display(&1, roots))
    extra = length(paths) - length(shown)
    Enum.join(shown, ", ") <> if(extra > 0, do: " +#{extra}", else: "")
  end

  defp display(path, roots) do
    case Enum.find(roots, &String.starts_with?(path, Path.expand(&1) <> "/")) do
      nil -> path
      root -> Path.relative_to(path, Path.expand(root))
    end
  end

  @doc "The recent-turns listing shown by a bare `/rewind`."
  @spec turn_list([map()]) :: String.t()
  def turn_list([]), do: gettext("Nothing to rewind yet.")

  def turn_list(turns) do
    rows =
      Enum.map(turns, fn %{n: n, preview: preview, files: files} ->
        preview = if preview == "", do: gettext("(no text)"), else: preview
        "#{n}. #{preview}#{files_suffix(files)}"
      end)

    Enum.join([gettext("Recent turns, newest first:") | rows] ++ ["", usage()], "\n")
  end

  defp files_suffix(files) when is_integer(files) and files > 0,
    do: " (" <> ngettext("%{count} file", "%{count} files", files, count: files) <> ")"

  defp files_suffix(_), do: ""

  @doc "How to pick what a rewind undoes."
  @spec usage() :: String.t()
  def usage do
    Enum.join(
      [
        gettext("/rewind N goes back N turns: the conversation and the files they changed."),
        gettext("/rewind N chat goes back in the conversation only."),
        gettext("/rewind N files puts files back and keeps the conversation.")
      ],
      "\n"
    )
  end

  @doc """
  Read the arguments of `/rewind` or `/retry`: `{:ok, count, mode}`, or `:error`. A bare
  command means one turn, both. `mode` is `:both`, `:chat` or `:files`; the words are
  accepted in any order and case, so `/rewind chat 2` and `/rewind 2 chat` do the same.
  """
  @spec parse_args(String.t()) :: {:ok, pos_integer(), :both | :chat | :files} | :error
  def parse_args(args) do
    words = args |> to_string() |> String.downcase() |> String.split()
    {modes, rest} = Enum.split_with(words, &(&1 in ["chat", "files", "both"]))

    with true <- at_most_one?(modes),
         {:ok, count} <- Pepe.Agent.Session.parse_rewind_count(Enum.join(rest, " ")) do
      {:ok, count, mode(modes)}
    else
      _ -> :error
    end
  end

  defp at_most_one?([]), do: true
  defp at_most_one?([_]), do: true
  defp at_most_one?(_), do: false

  @doc """
  What a typed `/rewind` asks for: `:list` for the bare command (show the turns to pick
  from), `{:ok, count, mode}` for a request, `:error` for something unreadable. Every
  surface reads its arguments through this, so they all agree.
  """
  @spec parse_rewind(String.t()) :: :list | {:ok, pos_integer(), :both | :chat | :files} | :error
  def parse_rewind(args) do
    if String.trim(to_string(args)) == "", do: :list, else: parse_args(args)
  end

  defp mode(["chat"]), do: :chat
  defp mode(["files"]), do: :files
  defp mode(_), do: :both

  @doc "The note the model reads when files were put back and the conversation kept."
  @spec agent_note(map(), pos_integer()) :: String.t()
  def agent_note(files, count) do
    parts =
      [
        {"Restored to how they were before those turns", files.restored},
        {"Removed (those turns had created them)", files.removed}
      ]
      |> Enum.reject(fn {_label, paths} -> paths == [] end)
      |> Enum.map(fn {label, paths} -> "#{label}: #{Enum.join(Enum.take(paths, 10), ", ")}" end)

    kept = files.skipped |> Enum.map(& &1.path) |> Enum.take(10)
    kept_text = if kept == [], do: "", else: " Left as they are (changed afterwards or not copied): #{Enum.join(kept, ", ")}."

    "<system-reminder>\nThe person asked for the files from the last #{count} turn(s) to be put back. " <>
      Enum.join(parts, ". ") <>
      "." <>
      kept_text <>
      " The conversation was kept, so what you did in those turns still happened in the conversation " <>
      "but no longer matches the files. Do not assume those changes exist.\n</system-reminder>"
  end
end

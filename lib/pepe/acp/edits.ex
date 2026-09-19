defmodule Pepe.ACP.Edits do
  @moduledoc """
  What a file-changing tool call is about to do, worked out *before* it runs, and the
  session-mode policy that decides whether a human has to look at it first.

  Two jobs, one module, because both start from the same question: "which file, and what
  will it contain afterwards?"

    * `proposal/3` computes the before/after of a `write_file` or `edit_file` call so an
      editor can render a real diff both on the tool call itself and on the permission
      request that asks about it - the difference between approving "edit_file" and
      approving *this change*. It never writes anything, and it gives up quietly (returns
      `nil`) rather than guess: a file that isn't readable text, a change too big to ship
      over a pipe, an `old_string` that would not match exactly once.

    * `mode_decision/5` is what the ACP session modes mean. `default` asks about
      everything, as it always did. `accept_edits` answers "allow once" on its own for an
      edit inside the project the editor has open (or the temp directory), and
      `dont_ask` does so for an edit anywhere. Neither ever answers for a sensitive path
      (credentials, keys, `.git`, Pepe's own home), for a call that is escalated by a
      policy plugin, or for a run that has taken in outside content: the same reasoning
      that withdraws a standing "always" approval after a `fetch_url` applies to a mode
      the person chose an hour ago.

  Paths are compared by their real location, symlinks followed, so a link inside the
  project that points at `~/.ssh` is judged as `~/.ssh`, not as "inside the project".
  """

  alias Pepe.Agent.Workspace
  alias Pepe.Permissions

  # A diff bigger than this is not worth shipping to an editor on every tool call, and
  # an editor that has to lay out a megabyte diff is not a better place to approve from.
  @max_diff_bytes 200_000

  @edit_tools ~w(write_file edit_file move_file)

  @sensitive_dirs ~w(.git .ssh .aws .gnupg .kube .docker .pepe)
  @sensitive_names ~w(id_rsa id_ed25519 id_ecdsa id_dsa .netrc .npmrc .pypirc .git-credentials credentials)

  @type proposal :: %{path: String.t(), old: String.t() | nil, new: String.t()}

  @doc "The tools whose calls the session modes may answer for."
  @spec edit_tools() :: [String.t()]
  def edit_tools, do: @edit_tools

  @doc """
  The before/after of a `write_file` or `edit_file` call, resolved against the editor's
  `cwd`, or `nil` when there is nothing trustworthy to show.
  """
  @spec proposal(String.t(), map(), String.t() | nil) :: proposal() | nil
  def proposal("write_file", %{"path" => path, "content" => content}, cwd)
      when is_binary(path) and is_binary(content) do
    full = resolve(path, cwd)

    with {:ok, old} <- read_existing(full),
         true <- small?(old, content) do
      %{path: full, old: old, new: content}
    else
      _ -> nil
    end
  end

  def proposal("edit_file", %{"path" => path, "old_string" => old_s, "new_string" => new_s}, cwd)
      when is_binary(path) and is_binary(old_s) and is_binary(new_s) do
    full = resolve(path, cwd)

    with {:ok, content} when is_binary(content) <- read_existing(full),
         1 <- occurrences(content, old_s),
         updated = String.replace(content, old_s, new_s, global: false),
         true <- small?(content, updated) do
      %{path: full, old: content, new: updated}
    else
      _ -> nil
    end
  end

  def proposal(_tool, _args, _cwd), do: nil

  @doc "An ACP `diff` content block for a proposal."
  @spec diff_content(proposal()) :: map()
  def diff_content(%{path: path, old: old, new: new}) do
    %{"type" => "diff", "path" => path, "oldText" => old, "newText" => new}
  end

  @doc """
  What a session mode says about one gated call: `:once` (allow it without asking) or
  `:ask` (put it in front of the person, exactly as before).
  """
  @spec mode_decision(String.t(), String.t(), term(), map(), String.t() | nil) :: :once | :ask
  def mode_decision(mode, name, raw_args, ctx, cwd) when mode in ["accept_edits", "dont_ask"] and name in @edit_tools do
    cond do
      ctx[:tainted] == true -> :ask
      ctx[:policy_reason] != nil -> :ask
      true -> decide(mode, edit_paths(name, Permissions.decode(raw_args), cwd), cwd)
    end
  end

  def mode_decision(_mode, _name, _raw_args, _ctx, _cwd), do: :ask

  defp decide(_mode, [], _cwd), do: :ask

  defp decide(mode, paths, cwd) do
    real = Enum.map(paths, &real_path/1)

    cond do
      Enum.any?(real, &sensitive?/1) -> :ask
      mode == "dont_ask" -> :once
      Enum.all?(real, &inside_allowed?(&1, cwd)) -> :once
      true -> :ask
    end
  end

  defp edit_paths("move_file", %{"from" => from, "to" => to}, cwd) when is_binary(from) and is_binary(to),
    do: [resolve(from, cwd), resolve(to, cwd)]

  defp edit_paths(name, %{"path" => path}, cwd) when name in ["write_file", "edit_file"] and is_binary(path),
    do: [resolve(path, cwd)]

  defp edit_paths(_name, _args, _cwd), do: []

  defp inside_allowed?(real, cwd), do: within?(real, cwd) or within?(real, System.tmp_dir!())

  defp within?(_real, nil), do: false

  defp within?(real, root) do
    root = real_path(root)
    real == root or String.starts_with?(real, root <> "/")
  end

  # A path is sensitive on its own components, not on where it lives: `.ssh` and `.git`
  # anywhere in the path, a credentials-shaped file name, or Pepe's own home (the config
  # that holds every key, whatever `PEPE_HOME` points at).
  defp sensitive?(real) do
    parts = real |> Path.split() |> Enum.map(&String.downcase/1)
    name = List.last(parts) || ""

    Enum.any?(@sensitive_dirs, &(&1 in parts)) or
      name in @sensitive_names or
      String.starts_with?(name, ".env") or
      String.ends_with?(name, ".pem") or
      String.ends_with?(name, ".key") or
      within?(real, Pepe.Config.home())
  end

  ###
  ### paths
  ###

  @doc false
  # The location the tool itself will use: relative to the editor's project, absolute
  # left alone (the same rule `Pepe.Agent.Workspace.resolve_in_ctx/2` applies under
  # `cwd_override`).
  @spec resolve(String.t(), String.t() | nil) :: String.t()
  def resolve(path, cwd), do: Workspace.resolve_in_ctx(path, %{cwd_override: cwd, cwd: cwd || File.cwd!()}) |> Path.expand()

  # `Path.expand/1` collapses `..` but does not follow links. Walk the path one component
  # at a time and follow every link met on the way (bounded, so a link loop ends).
  @doc false
  @spec real_path(String.t()) :: String.t()
  def real_path(path), do: walk(Path.split(Path.expand(path)), "", 0)

  defp walk(_parts, _acc, hops) when hops > 40, do: "/"
  defp walk([], acc, _hops), do: acc

  defp walk([root | rest], "", hops) when root == "/", do: walk(rest, "/", hops)
  defp walk([first | rest], "", hops), do: walk(rest, first, hops)

  defp walk([part | rest], acc, hops) do
    candidate = Path.join(acc, part)

    case File.read_link(candidate) do
      {:ok, target} ->
        resolved = Path.expand(target, Path.dirname(candidate))
        walk(Path.split(resolved) ++ rest, "", hops + 1)

      {:error, _} ->
        walk(rest, candidate, hops)
    end
  end

  ###
  ### file reading
  ###

  # `{:ok, nil}` for a file that doesn't exist yet (a write creates it), `{:ok, text}`
  # for readable UTF-8, `:error` for anything else - a directory, a binary, a permission
  # failure - where there is no honest diff to show.
  defp read_existing(full) do
    case File.read(full) do
      {:ok, text} -> if String.valid?(text), do: {:ok, text}, else: :error
      {:error, :enoent} -> {:ok, nil}
      {:error, _} -> :error
    end
  end

  defp small?(old, new), do: byte_size(old || "") + byte_size(new) <= @max_diff_bytes

  defp occurrences(content, sub), do: content |> String.split(sub) |> length() |> Kernel.-(1)
end

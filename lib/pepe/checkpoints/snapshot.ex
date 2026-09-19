defmodule Pepe.Checkpoints.Snapshot do
  @moduledoc """
  A bounded, in-memory picture of some files, taken before and after a tool runs so the
  difference between the two can be recorded.

  A snapshot never follows a symlink, never descends into build output or dependency
  trees, and never reads a file that looks like a credential. Those are the same three
  ways a "copy the directory" feature goes wrong (a cycle, a multi-gigabyte `node_modules`,
  a private key copied into a second place on disk), so the walker refuses them up front
  instead of leaving them to a size cap to catch by accident.

  Every limit degrades the same way: what fits is tracked, what does not is left out, and
  the snapshot says so (`partial?: true`) so the caller can tell the person the truth
  instead of implying everything was covered.
  """

  @max_files 3_000
  @max_blob_bytes 2 * 1_048_576
  @max_total_bytes 48 * 1_048_576

  # Directories whose contents are rebuilt by a tool, not authored: tracking them costs
  # most of the budget and restoring them means nothing.
  @skip_dirs ~w(.git .hg .svn node_modules _build deps .elixir_ls .next .nuxt .cache
                target dist build coverage .venv venv env __pycache__ .tox .gradle
                .idea .vscode .pytest_cache .mypy_cache .ruff_cache)

  @type file :: %{sha: String.t(), size: non_neg_integer(), mode: non_neg_integer(), data: binary() | nil}
  @type t :: %{files: %{Path.t() => file()}, partial?: boolean()}

  @doc "Directory names never descended into."
  def skip_dirs, do: @skip_dirs

  @doc """
  Whether a path looks like a credential or machine-local junk that must never be copied
  into the checkpoint store: dotenv files, private keys, certificates, keychains, OS
  metadata and logs.
  """
  @spec sensitive?(Path.t()) :: boolean()
  def sensitive?(path) do
    base = path |> Path.basename() |> String.downcase()

    base in [".env", ".ds_store", "thumbs.db", "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", ".netrc", ".npmrc", ".pypirc"] or
      String.starts_with?(base, ".env.") or
      String.starts_with?(base, "id_rsa") or
      Enum.any?(~w(.pem .key .p12 .pfx .keystore .jks .kdbx .log), &String.ends_with?(base, &1))
  end

  @doc """
  Snapshot every file under `roots` (each a file or a directory).

  A root that does not exist contributes nothing, which is exactly how "this file was
  created afterwards" shows up in a later diff. Options: `:max_files`, `:max_total_bytes`
  (both default to the module limits), `:skip` (a `(path -> boolean)` for extra paths to
  leave out, used to keep the store itself out of its own snapshots).
  """
  @spec take([Path.t()], keyword()) :: t()
  def take(roots, opts \\ []) do
    state = %{
      files: %{},
      count: 0,
      bytes: 0,
      partial?: false,
      max_files: Keyword.get(opts, :max_files, @max_files),
      max_bytes: Keyword.get(opts, :max_total_bytes, @max_total_bytes),
      skip: Keyword.get(opts, :skip, fn _ -> false end)
    }

    state = Enum.reduce(Enum.uniq(roots), state, fn root, acc -> visit(Path.expand(root), acc, true) end)
    %{files: state.files, partial?: state.partial?}
  end

  # An explicit root is followed even when it is a sensitive-looking or skipped name: the
  # agent named it, so the question is only whether it may be *copied*. A sensitive file is
  # left out of the manifest (it cannot be restored, and saying so beats a silent copy).
  defp visit(path, state, explicit?) do
    case :file.read_link_info(String.to_charlist(path)) do
      {:ok, info} -> visit_info(path, info, state, explicit?)
      {:error, _} -> state
    end
  end

  defp visit_info(path, info, state, explicit?) do
    cond do
      state.skip.(path) -> state
      elem_type(info) == :symlink -> state
      elem_type(info) == :directory -> walk_dir(path, state, explicit?)
      elem_type(info) == :regular -> add_file(path, info, state)
      true -> state
    end
  end

  # `:file.file_info` is a record: {:file_info, size, type, access, atime, mtime, ctime, mode, ...}
  defp elem_type(info), do: elem(info, 2)
  defp elem_size(info), do: elem(info, 1)
  defp elem_mode(info), do: elem(info, 7)

  defp walk_dir(path, state, explicit?) do
    if not explicit? and Path.basename(path) in @skip_dirs do
      state
    else
      case File.ls(path) do
        {:ok, names} -> names |> Enum.sort() |> Enum.reduce(state, &visit(Path.join(path, &1), &2, false))
        {:error, _} -> state
      end
    end
  end

  defp add_file(path, info, state) do
    cond do
      sensitive?(path) ->
        state

      state.count >= state.max_files ->
        %{state | partial?: true}

      true ->
        size = elem_size(info)
        mode = elem_mode(info)

        cond do
          size > @max_blob_bytes ->
            # Too big to copy or to hash cheaply: tracked by size and mtime only, so a change
            # is still noticed and reported, but it can never be restored.
            entry = %{sha: "big:#{size}:#{mtime_signature(info)}", size: size, mode: mode, data: nil}
            put(state, path, entry, 0)

          state.bytes + size > state.max_bytes ->
            %{state | partial?: true}

          true ->
            case File.read(path) do
              {:ok, data} -> put(state, path, %{sha: sha(data), size: size, mode: mode, data: data}, size)
              {:error, _} -> state
            end
        end
    end
  end

  defp put(state, path, entry, bytes),
    do: %{state | files: Map.put(state.files, path, entry), count: state.count + 1, bytes: state.bytes + bytes}

  defp mtime_signature(info) do
    case elem(info, 5) do
      {{y, mo, d}, {h, mi, s}} -> "#{y}#{mo}#{d}#{h}#{mi}#{s}"
      other -> inspect(other)
    end
  end

  @doc "Lowercase hex SHA-256 of a binary."
  @spec sha(binary()) :: String.t()
  def sha(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  @doc "Whether a recorded hash is a real content hash (a blob can exist for it), not a `big:` size marker."
  @spec restorable_sha?(term()) :: boolean()
  def restorable_sha?(sha) when is_binary(sha), do: String.match?(sha, ~r/\A[0-9a-f]{64}\z/)
  def restorable_sha?(_), do: false

  @doc """
  What changed between two snapshots, as one entry per path that differs:
  `%{path:, before: sha | nil, after: sha | nil, mode:, size:}`. `nil` means "no file".
  Sorted by path so a record reads the same however the walk happened to order things.
  """
  @spec diff(t(), t()) :: [map()]
  def diff(%{files: pre}, %{files: post}) do
    (Map.keys(pre) ++ Map.keys(post))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      b = Map.get(pre, path)
      a = Map.get(post, path)

      if (b && b.sha) == (a && a.sha) do
        []
      else
        [%{path: path, before: b && b.sha, after: a && a.sha, mode: (b || a).mode, size: (a || b).size}]
      end
    end)
  end
end

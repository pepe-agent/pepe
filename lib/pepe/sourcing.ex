defmodule Pepe.Sourcing do
  @moduledoc """
  Turn any source - a local path, a `.tar.gz`/`.tgz`/`.zip`, an `http(s)` URL, or a GitHub repo
  URL - into a local, inspectable staging location. Shared by `Pepe.Plugins` and
  `Pepe.Skills.Marketplace`: both download + verify + install a third-party thing, and this is
  the "download + verify" half - extracted so the archive-handling code (a security-relevant
  path: tar/zip extraction, archive-type detection) has exactly one copy to keep correct.

  A downloaded archive is identified by its actual bytes (`archive_format/1`), not by the
  URL it came from: a registry download endpoint (`Pepe.PepeHub`, for one) has no file
  extension in its path at all, so the only reliable signal is the file's own magic number.

  A caller parameterizes two things:

    * `single_ext` - the file extension a source can be a bare single file of
      (`".exs"` for a plugin, `".md"` for a skill).
    * `root_marker` - a 1-arg function ranking which directory inside an extracted archive
      is the real package root (see `root/2`); a plugin ranks `manifest.json` above any
      other `.exs`, a skill ranks `SKILL.md` above any other `.md`.
  """

  @doc """
  Stage `src` for inspection. Returns `{:ok, %{type: :file | :dir, path: ...}, cleanup_fun}`
  or `{:error, reason}`. The caller MUST call the returned `cleanup_fun` once done (a
  downloaded temp file or extracted temp dir otherwise leaks).
  """
  @spec stage(String.t(), String.t(), (String.t() -> boolean())) ::
          {:ok, %{type: :file | :dir, path: String.t()}, (-> :ok)} | {:error, term()}
  def stage(src, single_ext, root_marker)

  def stage("http" <> _ = url, single_ext, root_marker) do
    cond do
      github_repo?(url, single_ext) -> stage_github(url, root_marker)
      String.ends_with?(url, single_ext) -> stage_download(url, :file, single_ext, root_marker)
      true -> stage_download(url, :archive, single_ext, root_marker)
    end
  end

  def stage(path, single_ext, root_marker) do
    cond do
      not (File.exists?(path) or File.dir?(path)) -> {:error, :not_found}
      File.dir?(path) -> {:ok, %{type: :dir, path: path}, fn -> :ok end}
      archive?(path) -> stage_archive(path, fn -> :ok end, root_marker)
      String.ends_with?(path, single_ext) -> {:ok, %{type: :file, path: path}, fn -> :ok end}
      true -> {:error, :unsupported_source}
    end
  end

  @doc "Download `url` to a temp file. Returns `{:ok, path}` or `{:error, reason}`."
  @spec download(String.t()) :: {:ok, String.t()} | {:error, term()}
  def download(url) do
    case Req.get(url, receive_timeout: 30_000, redirect: true) do
      {:ok, %{status: s, body: body}} when s in 200..299 ->
        tmp = Path.join(System.tmp_dir!(), "pepe_dl_#{System.unique_integer([:positive])}")
        File.write!(tmp, body)
        {:ok, tmp}

      {:ok, %{status: s}} ->
        {:error, {:http, s}}

      other ->
        other
    end
  end

  @doc "Is `url` a plain GitHub repo link (not a direct file/archive)?"
  @spec github_repo?(String.t(), String.t()) :: boolean()
  def github_repo?(url, single_ext) do
    case URI.parse(url) do
      %{host: host, path: path} when is_binary(path) ->
        host in ["github.com", "www.github.com"] and github_target(path) != nil and
          not archive?(url) and not String.ends_with?(url, single_ext)

      _ ->
        false
    end
  end

  @doc false
  # `/owner/repo` or `/owner/repo/tree/branch` -> {owner, repo, branch|nil}, else nil.
  def github_target(path) do
    case path |> to_string() |> String.trim("/") |> String.split("/") do
      [owner, repo | rest] when owner != "" and repo != "" ->
        branch =
          case rest do
            ["tree", b | _] when b != "" -> b
            _ -> nil
          end

        {owner, String.replace_suffix(repo, ".git", ""), branch}

      _ ->
        nil
    end
  end

  @doc """
  The directory inside `tmp` that best satisfies `root_marker`, else `tmp` itself.

  `root_marker` ranks a basename: `false` for no match, a lower integer for a more
  specific one - a plugin's exact `manifest.json` or a skill's exact `SKILL.md`
  outranks any incidental same-extension file elsewhere in the tree (a package's own
  reference docs, say). Picking merely the first regular file matching a boolean
  predicate depended on `Path.wildcard/1`'s traversal order, which nothing guarantees,
  and silently resolved to the wrong directory the first time a package shipped more
  than one file the predicate could match.
  """
  @spec root(String.t(), (String.t() -> false | pos_integer())) :: String.t()
  def root(tmp, root_marker) do
    tmp
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.flat_map(fn path ->
      case root_marker.(Path.basename(path)) do
        false -> []
        rank -> [{rank, path}]
      end
    end)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
    |> case do
      nil -> tmp
      {_rank, match} -> Path.dirname(match)
    end
  end

  # --- internals ---------------------------------------------------------------------

  defp stage_download(url, kind, single_ext, root_marker) do
    case download(url) do
      {:ok, tmp} when kind == :file -> {:ok, %{type: :file, path: with_ext(tmp, url, single_ext)}, fn -> File.rm(tmp) end}
      {:ok, tmp} -> stage_archive(tmp, fn -> File.rm(tmp) end, root_marker)
      error -> error
    end
  end

  # A GitHub repo URL is fetched as a source archive. `owner/repo`, optionally
  # `.../tree/<branch>`; when no branch is given, `main` then `master` are tried.
  defp stage_github(url, root_marker) do
    {owner, repo, branch} = github_target(URI.parse(url).path)
    branches = if branch, do: [branch], else: ["main", "master"]
    urls = Enum.map(branches, &"https://codeload.github.com/#{owner}/#{repo}/tar.gz/refs/heads/#{&1}")

    case download_first(urls) do
      {:ok, tmp} -> stage_archive(tmp, fn -> File.rm(tmp) end, root_marker)
      error -> error
    end
  end

  defp download_first([url | rest]) do
    case download(url) do
      {:ok, tmp} -> {:ok, tmp}
      _ when rest != [] -> download_first(rest)
      error -> error
    end
  end

  defp download_first([]), do: {:error, :not_found}

  # A downloaded temp file has no extension; give it the source's so the caller's
  # placement step names it sensibly.
  defp with_ext(tmp, url, single_ext) do
    name = url |> URI.parse() |> Map.get(:path, "") |> to_string() |> Path.basename()
    dest = if name != "", do: Path.join(Path.dirname(tmp), name), else: tmp <> single_ext
    if dest != tmp, do: File.rename(tmp, dest)
    dest
  end

  defp stage_archive(archive_path, cleanup, root_marker) do
    tmp = Path.join(System.tmp_dir!(), "pepe_src_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    case extract(archive_path, tmp) do
      :ok ->
        {:ok, %{type: :dir, path: root(tmp, root_marker)},
         fn ->
           cleanup.()
           File.rm_rf(tmp)
           :ok
         end}

      {:error, reason} ->
        File.rm_rf(tmp)
        cleanup.()
        {:error, {:extract, reason}}
    end
  end

  defp extract(archive_path, dest) do
    case archive_format(archive_path) do
      :zip ->
        case :zip.extract(String.to_charlist(archive_path), cwd: String.to_charlist(dest)) do
          {:ok, _files} -> :ok
          {:error, reason} -> {:error, reason}
        end

      :tar ->
        :erl_tar.extract(String.to_charlist(archive_path), [:compressed, {:cwd, String.to_charlist(dest)}])
    end
  end

  # By content, not by name: a registry download endpoint has no file extension in its URL
  # at all (see the moduledoc), so the archive's own magic number is the only signal
  # available once it's already on disk. Anything that isn't a zip (`PK\x03\x04`) is handed
  # to `:erl_tar`, which already fails closed with a clear `{:error, _}` on real garbage.
  defp archive_format(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 4)) do
      {:ok, <<0x50, 0x4B, 0x03, 0x04>>} -> :zip
      _ -> :tar
    end
  end

  defp archive?(path),
    do: String.ends_with?(path, ".tar.gz") or String.ends_with?(path, ".tgz") or String.ends_with?(path, ".zip")
end

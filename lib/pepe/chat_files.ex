defmodule Pepe.ChatFiles do
  @moduledoc """
  Files an agent produced for a dashboard ("web:<id>") chat, kept for as long as the chat is.

  `Pepe.Tools.SendFile` copies the file here instead of linking the original, so the link
  keeps working after the workspace changes and, above all, so deleting a conversation can
  delete its files without ever touching anything of the agent's own. Each file lives in
  `<home>/data/chat_files/<session>/<token>/` as `file` plus a `meta.json` (name, caption,
  the turn that produced it). `delete_session/1` removes the whole session folder; it runs
  when the conversation is deleted or reset (`/new`, "Clear conversation").
  """

  alias Pepe.Config

  @token_re ~r/\A[A-Za-z0-9_-]{16,64}\z/

  @doc "Copy `path` in for session `key`; returns the entry the chat renders."
  @spec put(String.t(), Path.t(), String.t() | nil, non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def put(key, path, caption, turn) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    dir = Path.join(session_dir(key), token)
    filename = Path.basename(path)
    meta = %{"filename" => filename, "caption" => caption, "turn" => turn, "at" => System.system_time(:millisecond)}

    with :ok <- File.mkdir_p(dir),
         :ok <- File.cp(path, Path.join(dir, "file")),
         :ok <- File.write(Path.join(dir, "meta.json"), Jason.encode!(meta)) do
      {:ok, entry(token, meta)}
    else
      {:error, reason} ->
        File.rm_rf(dir)
        {:error, reason}
    end
  end

  @doc "The session's files, oldest first."
  @spec list(String.t() | nil) :: [map()]
  def list(nil), do: []

  def list(key) do
    session_dir(key)
    |> Path.join("*/meta.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn meta_path ->
      case read_meta(meta_path) do
        {:ok, meta} -> [{meta["at"] || 0, entry(meta_path |> Path.dirname() |> Path.basename(), meta)}]
        :error -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @doc "Where the file behind a download token is, across every session."
  @spec find(String.t()) :: {:ok, %{path: Path.t(), filename: String.t()}} | :error
  def find(token) when is_binary(token) do
    with true <- Regex.match?(@token_re, token),
         [meta_path | _] <- Path.wildcard(Path.join([root(), "*", token, "meta.json"])),
         {:ok, meta} <- read_meta(meta_path),
         path = Path.join(Path.dirname(meta_path), "file"),
         true <- File.regular?(path) do
      {:ok, %{path: path, filename: meta["filename"] || "download"}}
    else
      _ -> :error
    end
  end

  def find(_), do: :error

  @doc "Delete every file of the session."
  @spec delete_session(String.t() | nil) :: :ok
  def delete_session(nil), do: :ok

  def delete_session(key) do
    File.rm_rf(session_dir(key))
    :ok
  end

  defp entry(token, meta),
    do: %{token: token, filename: meta["filename"] || "download", caption: meta["caption"], turn: meta["turn"] || 0}

  defp read_meta(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{} = meta} <- Jason.decode(raw) do
      {:ok, meta}
    else
      _ -> :error
    end
  end

  defp root, do: Path.join([Config.home(), "data", "chat_files"])

  # A hash, not the key: session keys carry ":" and user-chosen text, which have no business
  # being a path segment.
  defp session_dir(key), do: Path.join(root(), :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> binary_part(0, 24))
end

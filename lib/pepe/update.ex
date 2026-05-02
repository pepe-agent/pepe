defmodule Pepe.Update do
  @moduledoc """
  Self-update for the packaged `pepe` binary: check the latest GitHub release, download
  the build for this OS/arch, and swap it in place of the running executable (the current
  binary is renamed aside first, so a bad update is trivially reversible and the running
  process keeps working until it's restarted).

  Only meaningful for the standalone binary. From a source checkout (`mix pepe`) there is
  nothing to swap, so `run/0` returns `{:error, :from_source}` and callers point the user
  at `git pull` instead.
  """
  require Logger

  @repo "pepe-agent/pepe"

  @doc "The running version."
  def current, do: to_string(Application.spec(:pepe, :vsn) || "0.0.0")

  @doc "True when running from a source checkout (Mix present) rather than the binary."
  def running_from_source?, do: Code.ensure_loaded?(Mix)

  @doc "The release asset name for this OS/arch, or nil if unsupported."
  def target do
    arch = to_string(:erlang.system_info(:system_architecture))
    arm? = String.contains?(arch, "aarch64") or String.starts_with?(arch, "arm")

    case :os.type() do
      {:unix, :darwin} -> "pepe_macos_#{if arm?, do: "arm", else: "x86"}"
      {:unix, :linux} -> "pepe_linux_#{if arm?, do: "arm", else: "x86"}"
      {:win32, _} -> "pepe_windows.exe"
      _ -> nil
    end
  end

  @doc "Path to the `pepe` executable to replace (its spot on PATH, else ~/.local/bin/pepe)."
  def binary_path do
    System.find_executable("pepe") || Path.join([System.user_home!(), ".local", "bin", "pepe"])
  end

  @doc "The latest published version (tag without the `v`), or `{:error, reason}`."
  def latest do
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.get("https://api.github.com/repos/#{@repo}/releases/latest",
           receive_timeout: 10_000,
           headers: [{"accept", "application/vnd.github+json"}]
         ) do
      {:ok, %{status: 200, body: %{"tag_name" => "v" <> v}}} -> {:ok, v}
      {:ok, %{status: 200, body: %{"tag_name" => v}}} when is_binary(v) -> {:ok, v}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      other -> other
    end
  end

  @doc "Is `latest` newer than the running version?"
  def newer?(latest, current \\ current()) do
    case {Version.parse(latest), Version.parse(current)} do
      {{:ok, l}, {:ok, c}} -> Version.compare(l, c) == :gt
      _ -> latest != current
    end
  end

  @doc """
  Update to the latest release when one is newer. Returns `{:ok, :updated, version}`,
  `{:ok, :up_to_date, version}`, or `{:error, reason}` (`:from_source`,
  `:unsupported_platform`, an HTTP/transport error).
  """
  def run do
    cond do
      running_from_source?() -> {:error, :from_source}
      is_nil(target()) -> {:error, :unsupported_platform}
      true -> check_and_swap()
    end
  end

  defp check_and_swap do
    with {:ok, version} <- latest() do
      if newer?(version) do
        swap(version)
      else
        {:ok, :up_to_date, current()}
      end
    end
  end

  defp swap(version) do
    {:ok, _} = Application.ensure_all_started(:req)

    with {:ok, body} <- download(target()),
         :ok <- verify(body, target()) do
      install(body, version)
    end
  end

  defp download(asset) do
    url = "https://github.com/#{@repo}/releases/latest/download/#{asset}"

    case Req.get(url, receive_timeout: 120_000, redirect: true) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) > 0 -> {:ok, body}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Check the download against the SHA256SUMS the release publishes. This is the only
  # thing standing between a tampered asset and an overwritten binary on the user's box,
  # so a checksum that is missing, unreadable, or simply absent for our asset is a
  # refusal, never a shrug: passing on a sum we could not check would defeat having one.
  defp verify(body, asset) do
    with {:ok, sums} <- download("SHA256SUMS"),
         {:ok, expected} <- sum_for(sums, asset) do
      actual = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(actual, expected),
        do: :ok,
        else: {:error, {:checksum_mismatch, asset}}
    else
      {:error, reason} -> {:error, {:checksum_unavailable, reason}}
    end
  end

  # One `<sha256>  <filename>` per line, the format `sha256sum` itself writes.
  defp sum_for(sums, asset) do
    sums
    |> String.split("\n", trim: true)
    |> Enum.find_value({:error, {:no_checksum_for, asset}}, fn line ->
      case String.split(line, ~r/\s+/, trim: true) do
        [sum, ^asset] -> {:ok, String.downcase(sum)}
        _ -> nil
      end
    end)
  end

  defp install(body, version) do
    path = binary_path()
    tmp = "#{path}.new"

    File.mkdir_p!(Path.dirname(path))
    File.write!(tmp, body)
    File.chmod!(tmp, 0o755)
    # Move the running binary aside (kept as .old), then put the new one in place.
    _ = File.rename(path, "#{path}.old")
    File.rename!(tmp, path)
    Logger.info("[update] updated pepe to v#{version} at #{path}")
    {:ok, :updated, version}
  end
end

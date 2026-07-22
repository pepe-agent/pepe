defmodule Pepe.Browser.Fetcher do
  @moduledoc """
  Last resort when no Chrome/Chromium was found on the machine: download one.

  Fetches `chrome-headless-shell` (a minimal, display-less CDP-drivable build - no
  `.app` bundle, no Xvfb) from Google's **Chrome for Testing** feed - the same
  versioned, stable download source Playwright itself resolves through internally.
  Cached under `~/.cache/pepe/browser/` (the same convention the Docker image's own
  `/tools` doc already describes: regenerable, architecture-bound, not backed up),
  so this only runs once per machine.

  Deliberately narrower than a full Playwright/Puppeteer install: no `--with-deps`,
  no system package installation (that needs `apt`/root, which a headless-shell
  binary launch does not - though the *shared libraries* it links against still
  have to already be on the machine; on a from-scratch minimal Linux image with
  none of them, downloading the binary alone won't make it launch - see
  `PEPE_IMAGE_APT_PACKAGES=chromium` for that case instead).

  Opt out with `PEPE_BROWSER_AUTO_DOWNLOAD=0` if you'd rather this fail with a
  clear error and install Chrome yourself.
  """

  require Logger

  @manifest_url "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"
  @product "chrome-headless-shell"
  @manifest_timeout 15_000
  @download_timeout 120_000

  @doc "A cached download if one exists, else fetch and cache one. `{:ok, path} | {:error, reason}`."
  def ensure_chrome do
    if enabled?() do
      case cached_binary() do
        {:ok, path} -> {:ok, path}
        :none -> download()
      end
    else
      {:error, :chrome_not_found}
    end
  end

  defp enabled?, do: System.get_env("PEPE_BROWSER_AUTO_DOWNLOAD") != "0"

  # Overridable so tests can redirect this away from the real machine's home
  # directory instead of downloading into (or asserting against) it.
  defp cache_dir do
    System.get_env("PEPE_BROWSER_CACHE_DIR") || Path.join([System.user_home!(), ".cache", "pepe", "browser"])
  end

  defp cached_binary do
    case platform() do
      {:ok, plat} ->
        exe = Path.join(cache_dir(), executable_name(plat))
        if File.exists?(exe), do: {:ok, exe}, else: :none

      {:error, _} ->
        :none
    end
  end

  defp download do
    with {:ok, plat} <- platform(),
         {:ok, url} <- resolve_download_url(plat) do
      Logger.info("[browser] no Chrome found - downloading chrome-headless-shell (~100-150MB, one time)")

      with {:ok, zip} <- fetch_zip(url),
           {:ok, extracted} <- extract(zip),
           {:ok, exe} <- install(extracted, plat) do
        File.rm(zip)
        Logger.info("[browser] downloaded chrome-headless-shell to #{exe}")
        {:ok, exe}
      end
    end
  end

  ###
  ### platform
  ###

  # Google publishes Chrome for Testing for these five platform strings only - no
  # Linux ARM build exists, so a Linux ARM host correctly falls through to
  # :unsupported_platform (a real gap, not a bug: install Chromium via the system
  # package manager there instead).
  defp platform do
    arch = arch_string()

    case :os.type() do
      {:unix, :darwin} -> if arm64?(arch), do: {:ok, "mac-arm64"}, else: {:ok, "mac-x64"}
      {:unix, _linux} -> if String.starts_with?(arch, "x86_64"), do: {:ok, "linux64"}, else: {:error, :unsupported_platform}
      {:win32, _} -> if String.starts_with?(arch, "x86_64"), do: {:ok, "win64"}, else: {:ok, "win32"}
    end
  end

  defp arch_string, do: :erlang.system_info(:system_architecture) |> List.to_string()

  # `:erlang.system_info(:system_architecture)` returns a full target triple
  # ("aarch64-apple-darwin", "x86_64-pc-linux-gnu"), not a bare arch name - matching it
  # with `in ["aarch64", "arm64"]` looks right but never matches, silently downloading
  # the wrong CPU's binary (found via a real launch failure: it ran fine under Rosetta
  # emulation on Apple Silicon, right up until the DevTools handshake, which fails
  # silently instead of loudly). Prefix match instead, everywhere arch is checked.
  defp arm64?(arch), do: String.starts_with?(arch, "aarch64") or String.starts_with?(arch, "arm64")

  defp executable_name(plat) when plat in ["win32", "win64"], do: "chrome-headless-shell.exe"
  defp executable_name(_plat), do: "chrome-headless-shell"

  ###
  ### manifest + download
  ###

  defp resolve_download_url(plat) do
    case Req.get(@manifest_url, receive_timeout: @manifest_timeout) do
      {:ok, %{status: 200, body: body}} -> find_platform_url(decode(body), plat)
      {:ok, %{status: status}} -> {:error, {:manifest_fetch_failed, status}}
      {:error, reason} -> {:error, {:manifest_fetch_failed, reason}}
    end
  end

  defp decode(body) when is_binary(body), do: Jason.decode!(body)
  defp decode(body), do: body

  defp find_platform_url(manifest, plat) do
    downloads = get_in(manifest, ["channels", "Stable", "downloads", @product]) || []

    case Enum.find(downloads, &(&1["platform"] == plat)) do
      %{"url" => url} -> {:ok, url}
      nil -> {:error, {:no_download_for_platform, plat}}
    end
  end

  defp fetch_zip(url) do
    tmp = Path.join(System.tmp_dir!(), "pepe-chrome-#{System.unique_integer([:positive])}.zip")

    case Req.get(url, receive_timeout: @download_timeout, into: File.stream!(tmp)) do
      {:ok, %{status: 200}} -> {:ok, tmp}
      {:ok, %{status: status}} -> {:error, {:download_failed, status}}
      {:error, reason} -> {:error, {:download_failed, reason}}
    end
  end

  ###
  ### extract + install
  ###

  defp extract(zip_path) do
    dest = Path.join(System.tmp_dir!(), "pepe-chrome-extract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dest)

    case :zip.unzip(String.to_charlist(zip_path), cwd: String.to_charlist(dest)) do
      {:ok, _files} -> {:ok, dest}
      {:error, reason} -> {:error, {:extract_failed, reason}}
    end
  end

  # The archive nests the executable one level down (e.g. `chrome-headless-shell-linux64/`),
  # a name that itself carries the CfT version/platform and isn't worth hardcoding - find it
  # by name instead, and move its whole containing directory into the cache (the executable
  # needs its .pak/.dat/shared-lib siblings sitting right next to it to run at all).
  defp install(extracted_dir, plat) do
    exe_name = executable_name(plat)

    case find_executable(extracted_dir, exe_name) do
      {:ok, found} ->
        File.mkdir_p!(Path.dirname(cache_dir()))
        File.rm_rf(cache_dir())
        File.cp_r!(Path.dirname(found), cache_dir())
        final = Path.join(cache_dir(), exe_name)
        File.chmod(final, 0o755)
        File.rm_rf(extracted_dir)
        {:ok, final}

      :error ->
        File.rm_rf(extracted_dir)
        {:error, :executable_not_found_in_archive}
    end
  end

  defp find_executable(dir, exe_name) do
    dir
    |> Path.join("**/#{exe_name}")
    |> Path.wildcard()
    |> List.first()
    |> case do
      nil -> :error
      path -> {:ok, path}
    end
  end
end

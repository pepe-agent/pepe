defmodule Pepe.Browser.Fetcher do
  @moduledoc """
  Last resort when no Chrome/Chromium was found on the machine: download one.

  Fetches `chrome-headless-shell` (a minimal, display-less CDP-drivable build - no
  `.app` bundle, no Xvfb) from Google's **Chrome for Testing** feed - the same
  versioned, stable download source Playwright itself resolves through internally.
  Cached under `~/.cache/pepe/browser/` (the same convention the Docker image's own
  `/tools` doc already describes: regenerable, architecture-bound, not backed up),
  so this only runs once per machine.

  **Linux on ARM is the one platform Chrome for Testing doesn't publish for at
  all** (confirmed against Google's own manifest, not assumed) - Playwright's own
  CDN is the fallback there instead, fetched the same way (its `browsers.json`
  manifest, then a plain HTTPS download, no npm/Node.js involved). That CDN also
  doesn't serve `chrome-headless-shell` as its own artifact (every URL shape tried
  returned a gateway error - confirmed empirically, not assumed either), so the
  ARM path downloads full Chromium instead: a real, larger fallback, but a
  fallback only Linux ARM hosts ever take.

  Deliberately narrower than a full Playwright/Puppeteer install: no `--with-deps`,
  no system package installation (that needs `apt`/root, which a downloaded binary
  launch does not - though the *shared libraries* it links against still have to
  already be on the machine; on a from-scratch minimal Linux image with none of
  them, downloading the binary alone won't make it launch - see
  `PEPE_IMAGE_APT_PACKAGES=chromium` for that case instead, or the Dockerfile's own
  bundled set for the official image).

  Opt out with `PEPE_BROWSER_AUTO_DOWNLOAD=0` if you'd rather this fail with a
  clear error and install Chrome yourself.
  """

  require Logger

  @cft_manifest_url "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"
  @cft_product "chrome-headless-shell"

  # Pinned to a real release tag, not `main` - Chrome for Testing's own manifest is
  # explicitly curated as "last known good"; Playwright's `browsers.json` on its
  # development branch carries no such guarantee, so a stable tag is the closer
  # equivalent. Bump this occasionally, same spirit as the Dockerfile's own pinned
  # versions - it only affects the one platform (Linux ARM) that has no other source.
  @playwright_manifest_url "https://raw.githubusercontent.com/microsoft/playwright/release-1.55/packages/playwright-core/browsers.json"
  @playwright_download_host "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds"

  @manifest_timeout 15_000
  @download_timeout 180_000

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
      {:ok, {source, plat}} ->
        exe = Path.join(cache_dir(), executable_name(source, plat))
        if File.exists?(exe), do: {:ok, exe}, else: :none

      {:error, _} ->
        :none
    end
  end

  defp download do
    with {:ok, {source, plat}} <- platform(),
         {:ok, url} <- resolve_download_url(source, plat) do
      Logger.info("[browser] no Chrome found - downloading one (~100-200MB, one time)")

      case fetch_zip(url) do
        {:ok, zip} -> extract_and_install(zip, source, plat)
        {:error, _} = error -> error
      end
    end
  end

  # Always removes the downloaded zip, not just on success: a failed extract/install
  # still leaves the download (up to ~200MB) behind in the tmp dir otherwise.
  defp extract_and_install(zip, source, plat) do
    result =
      with {:ok, extracted} <- extract(zip),
           {:ok, exe} <- install(extracted, source, plat) do
        Logger.info("[browser] downloaded a browser to #{exe}")
        {:ok, exe}
      end

    File.rm(zip)
    result
  end

  ###
  ### platform
  ###

  defp platform, do: resolve_platform(:os.type(), arch_string(), windows_arch_hint())

  # {source, platform-string}: which feed to fetch from, and that feed's own name for
  # this OS/CPU. A pure function of (os_type, arch, windows_arch_hint) - `platform/0` is
  # the only caller that actually reads the real machine, so this stays directly testable
  # without mocking `:os`/`:erlang` themselves (risky: those are called by unrelated code
  # throughout the same test process, not just this one). Chrome for Testing covers
  # everything except Linux on ARM (no build published there at all - confirmed
  # against Google's own manifest); that one case routes to Playwright's CDN instead
  # (see moduledoc).
  @doc false
  def resolve_platform(os_type, arch, windows_arch_hint \\ nil) do
    case os_type do
      {:unix, :darwin} -> if arm64?(arch), do: {:ok, {:cft, "mac-arm64"}}, else: {:ok, {:cft, "mac-x64"}}
      {:unix, _linux} -> resolve_linux_platform(arch)
      {:win32, _} -> if windows_64bit?(windows_arch_hint), do: {:ok, {:cft, "win64"}}, else: {:ok, {:cft, "win32"}}
    end
  end

  defp resolve_linux_platform(arch) do
    cond do
      String.starts_with?(arch, "x86_64") -> {:ok, {:cft, "linux64"}}
      arm64?(arch) -> {:ok, {:playwright, "linux-arm64"}}
      true -> {:error, :unsupported_platform}
    end
  end

  defp arch_string, do: :erlang.system_info(:system_architecture) |> List.to_string()

  # On every other OS, `arch_string/0` is a real CPU triple - but on Windows,
  # `:erlang.system_info(:system_architecture)` is always the literal string "win32",
  # 32-bit or 64-bit machine alike (an ERTS/Windows build detail, not a CPU name), so
  # `resolve_platform/3`'s win32 branch needs a different signal entirely. Windows itself
  # sets `PROCESSOR_ARCHITEW6432` only for a 32-bit process running under WOW64 on a
  # 64-bit OS, holding the *real* architecture then; `PROCESSOR_ARCHITECTURE` alone is
  # enough the rest of the time (a native 64-bit process already reports its own real
  # 64-bit architecture there). Not read inside resolve_platform/3 itself so that
  # function stays a pure, directly-testable function of its arguments.
  defp windows_arch_hint, do: System.get_env("PROCESSOR_ARCHITEW6432") || System.get_env("PROCESSOR_ARCHITECTURE")

  defp windows_64bit?(hint) when is_binary(hint), do: String.upcase(hint) in ["AMD64", "ARM64"]
  defp windows_64bit?(_hint), do: false

  # `:erlang.system_info(:system_architecture)` returns a full target triple
  # ("aarch64-apple-darwin", "x86_64-pc-linux-gnu"), not a bare arch name - matching it
  # with `in ["aarch64", "arm64"]` looks right but never matches, silently downloading
  # the wrong CPU's binary (found via a real launch failure: it ran fine under Rosetta
  # emulation on Apple Silicon, right up until the DevTools handshake, which fails
  # silently instead of loudly). Prefix match instead, everywhere arch is checked.
  defp arm64?(arch), do: String.starts_with?(arch, "aarch64") or String.starts_with?(arch, "arm64")

  defp executable_name(:cft, plat) when plat in ["win32", "win64"], do: "chrome-headless-shell.exe"
  defp executable_name(:cft, _plat), do: "chrome-headless-shell"
  defp executable_name(:playwright, _plat), do: "chrome"

  ###
  ### manifest + download
  ###

  defp resolve_download_url(:cft, plat) do
    case Req.get(@cft_manifest_url, receive_timeout: @manifest_timeout) do
      {:ok, %{status: 200, body: body}} -> with_decoded(body, &find_cft_url(&1, plat))
      {:ok, %{status: status}} -> {:error, {:manifest_fetch_failed, status}}
      {:error, reason} -> {:error, {:manifest_fetch_failed, reason}}
    end
  end

  defp resolve_download_url(:playwright, plat) do
    case Req.get(@playwright_manifest_url, receive_timeout: @manifest_timeout) do
      {:ok, %{status: 200, body: body}} -> with_decoded(body, &find_playwright_url(&1, plat))
      {:ok, %{status: status}} -> {:error, {:manifest_fetch_failed, status}}
      {:error, reason} -> {:error, {:manifest_fetch_failed, reason}}
    end
  end

  # A 200 with a body that isn't valid JSON (a captive portal, a misbehaving proxy) must
  # become the same `manifest_fetch_failed` a bad status already does, not an unhandled
  # `Jason.decode!` crash that turns into `Session.init`'s generic "could not start" message.
  defp with_decoded(body, fun) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> fun.(decoded)
      {:error, reason} -> {:error, {:manifest_fetch_failed, {:invalid_json, reason}}}
    end
  end

  defp with_decoded(body, fun), do: fun.(body)

  # Public (but undocumented) purely so tests can feed a fixture manifest directly,
  # the same reason `resolve_platform/2` is - real manifest shapes were confirmed with
  # a live fetch before being encoded here, but the parsing logic itself deserves its
  # own regression coverage independent of mocking the HTTP layer.
  @doc false
  def find_cft_url(manifest, plat) do
    downloads = get_in(manifest, ["channels", "Stable", "downloads", @cft_product]) || []

    case Enum.find(downloads, &(&1["platform"] == plat)) do
      %{"url" => url} -> {:ok, url}
      nil -> {:error, {:no_download_for_platform, plat}}
    end
  end

  @doc false
  def find_playwright_url(manifest, plat) do
    browsers = manifest["browsers"] || []

    case Enum.find(browsers, &(&1["name"] == "chromium")) do
      %{"revision" => rev} -> {:ok, "#{@playwright_download_host}/chromium/#{rev}/chromium-#{plat}.zip"}
      nil -> {:error, {:no_download_for_platform, plat}}
    end
  end

  defp fetch_zip(url) do
    tmp = Path.join(System.tmp_dir!(), "pepe-chrome-#{System.unique_integer([:positive])}.zip")

    case Req.get(url, receive_timeout: @download_timeout, into: File.stream!(tmp)) do
      {:ok, %{status: 200}} ->
        {:ok, tmp}

      {:ok, %{status: status}} ->
        # `into: File.stream!/1` writes the response body (an error page, on a non-200)
        # to `tmp` as it streams - clean it up rather than leaving a stray file behind.
        File.rm(tmp)
        {:error, {:download_failed, status}}

      {:error, reason} ->
        File.rm(tmp)
        {:error, {:download_failed, reason}}
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

  # The archive nests the executable one level down (e.g. `chrome-headless-shell-linux64/`
  # or, for Playwright, `chrome-linux/`) - a name that itself carries the version/platform
  # and isn't worth hardcoding - find it by name instead, and move its whole containing
  # directory into the cache (the executable needs its .pak/.dat/shared-lib siblings
  # sitting right next to it to run at all).
  defp install(extracted_dir, source, plat) do
    exe_name = executable_name(source, plat)

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

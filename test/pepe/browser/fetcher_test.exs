defmodule Pepe.Browser.FetcherTest do
  use ExUnit.Case, async: false
  use Mimic

  import Bitwise

  alias Pepe.Browser.Fetcher

  @manifest %{
    "channels" => %{
      "Stable" => %{
        "downloads" => %{
          "chrome-headless-shell" => [
            %{"platform" => "mac-arm64", "url" => "https://example.test/mac-arm64.zip"},
            %{"platform" => "mac-x64", "url" => "https://example.test/mac-x64.zip"},
            %{"platform" => "linux64", "url" => "https://example.test/linux64.zip"},
            %{"platform" => "win64", "url" => "https://example.test/win64.zip"},
            %{"platform" => "win32", "url" => "https://example.test/win32.zip"}
          ]
        }
      }
    }
  }

  setup do
    cache_dir = Path.join(System.tmp_dir!(), "pepe_fetcher_cache_#{System.unique_integer([:positive])}")
    prev_cache = System.get_env("PEPE_BROWSER_CACHE_DIR")
    prev_enabled = System.get_env("PEPE_BROWSER_AUTO_DOWNLOAD")
    System.put_env("PEPE_BROWSER_CACHE_DIR", cache_dir)

    on_exit(fn ->
      if prev_cache, do: System.put_env("PEPE_BROWSER_CACHE_DIR", prev_cache), else: System.delete_env("PEPE_BROWSER_CACHE_DIR")
      if prev_enabled, do: System.put_env("PEPE_BROWSER_AUTO_DOWNLOAD", prev_enabled), else: System.delete_env("PEPE_BROWSER_AUTO_DOWNLOAD")
      File.rm_rf(cache_dir)
    end)

    %{cache_dir: cache_dir}
  end

  # A real zip, built in memory - the archive's own top directory name is irrelevant
  # (Fetcher finds the executable by name via a wildcard, not a hardcoded path), so
  # this fixture works regardless of which platform string this test machine resolves to.
  defp fake_zip do
    {:ok, {_name, zip}} =
      :zip.create(~c"fixture.zip", [{~c"chrome-headless-shell-x/chrome-headless-shell", "fake chrome binary"}], [:memory])

    zip
  end

  test "downloads, extracts, and caches on a cold start" do
    zip = fake_zip()
    parent = self()

    Mimic.expect(Req, :get, fn url, _opts ->
      send(parent, {:manifest_fetch, url})
      {:ok, %{status: 200, body: @manifest}}
    end)

    Mimic.expect(Req, :get, fn url, opts ->
      send(parent, {:zip_fetch, url})
      File.write!(opts[:into].path, zip)
      {:ok, %{status: 200}}
    end)

    assert {:ok, exe} = Fetcher.ensure_chrome()
    assert File.read!(exe) == "fake chrome binary"
    assert (File.stat!(exe).mode &&& 0o111) != 0
    assert_received {:manifest_fetch, "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"}
    assert_received {:zip_fetch, "https://example.test/" <> _}
  end

  test "a second call hits the cache and never touches the network", %{cache_dir: cache_dir} do
    File.mkdir_p!(cache_dir)
    exe = Path.join(cache_dir, "chrome-headless-shell")
    File.write!(exe, "already here")

    Mimic.reject(&Req.get/2)
    assert {:ok, ^exe} = Fetcher.ensure_chrome()
  end

  test "PEPE_BROWSER_AUTO_DOWNLOAD=0 refuses without touching the network" do
    System.put_env("PEPE_BROWSER_AUTO_DOWNLOAD", "0")
    Mimic.reject(&Req.get/2)
    assert {:error, :chrome_not_found} = Fetcher.ensure_chrome()
  end

  test "a manifest fetch failure is reported, not raised" do
    Mimic.expect(Req, :get, fn _url, _opts -> {:error, :timeout} end)
    assert {:error, {:manifest_fetch_failed, :timeout}} = Fetcher.ensure_chrome()
  end

  test "no download listed for this platform is reported clearly" do
    empty = put_in(@manifest, ["channels", "Stable", "downloads", "chrome-headless-shell"], [])
    Mimic.expect(Req, :get, fn _url, _opts -> {:ok, %{status: 200, body: empty}} end)

    assert {:error, {:no_download_for_platform, _plat}} = Fetcher.ensure_chrome()
  end

  describe "resolve_platform/2" do
    # A pure function of (os_type, arch-string) - tested directly rather than through
    # `ensure_chrome/0`, since faking what machine this is by mocking `:os`/`:erlang`
    # themselves would affect unrelated code sharing the same test process. This is
    # exactly the shape of bug a live download test already caught once (arch string is
    # a full target triple, not a bare name - an exact `in [...]` match silently never
    # matches), so every branch gets its own case instead of one happy-path check.

    test "macOS arm64 uses Chrome for Testing's mac-arm64 build" do
      assert {:ok, {:cft, "mac-arm64"}} = Fetcher.resolve_platform({:unix, :darwin}, "aarch64-apple-darwin23.0.0")
    end

    test "macOS intel uses Chrome for Testing's mac-x64 build" do
      assert {:ok, {:cft, "mac-x64"}} = Fetcher.resolve_platform({:unix, :darwin}, "x86_64-apple-darwin23.0.0")
    end

    test "linux x86_64 uses Chrome for Testing's linux64 build" do
      assert {:ok, {:cft, "linux64"}} = Fetcher.resolve_platform({:unix, :linux}, "x86_64-pc-linux-gnu")
    end

    test "linux aarch64 falls back to Playwright's CDN, not Chrome for Testing" do
      assert {:ok, {:playwright, "linux-arm64"}} = Fetcher.resolve_platform({:unix, :linux}, "aarch64-unknown-linux-gnu")
    end

    test "linux arm64 (the other common triple spelling) also routes to Playwright" do
      assert {:ok, {:playwright, "linux-arm64"}} = Fetcher.resolve_platform({:unix, :linux}, "arm64-unknown-linux-gnu")
    end

    test "an unrecognized linux arch is reported, not guessed at" do
      assert {:error, :unsupported_platform} = Fetcher.resolve_platform({:unix, :linux}, "riscv64-unknown-linux-gnu")
    end

    test "windows x86_64 uses Chrome for Testing's win64 build" do
      assert {:ok, {:cft, "win64"}} = Fetcher.resolve_platform({:win32, :nt}, "x86_64-pc-windows-msvc")
    end

    test "windows non-x86_64 uses Chrome for Testing's win32 build" do
      assert {:ok, {:cft, "win32"}} = Fetcher.resolve_platform({:win32, :nt}, "win32")
    end
  end

  describe "find_playwright_url/2" do
    # A real shape, fetched live from Playwright's own browsers.json before being
    # trimmed down to a fixture here.
    @playwright_manifest %{
      "browsers" => [
        %{"name" => "chromium", "revision" => "1193", "browserVersion" => "140.0.7339.186"},
        %{"name" => "chromium-headless-shell", "revision" => "1193"},
        %{"name" => "firefox", "revision" => "1490"}
      ]
    }

    test "builds a URL matching Playwright's real, curl-verified download host and path shape" do
      # host + /builds/chromium/<revision>/chromium-<platform>.zip was confirmed with a live
      # curl against the real CDN before being asserted here: a 200 for chromium-linux-arm64.zip,
      # chromium-linux.zip, chromium-win64.zip, and chromium-mac-arm64.zip.
      assert {:ok, url} = Fetcher.find_playwright_url(@playwright_manifest, "linux-arm64")

      assert url ==
               "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/chromium/1193/chromium-linux-arm64.zip"
    end

    test "uses the full chromium entry's revision, not chromium-headless-shell's" do
      # Deliberate: Playwright's CDN doesn't serve chromium-headless-shell as its own
      # artifact (every URL shape tried returned a gateway error, confirmed live) - the
      # ARM fallback downloads full Chromium, so it must resolve the "chromium" entry
      # specifically, not whichever browser entry happens to come first.
      manifest = %{
        "browsers" => [%{"name" => "chromium-headless-shell", "revision" => "999"}, %{"name" => "chromium", "revision" => "1193"}]
      }

      assert {:ok, url} = Fetcher.find_playwright_url(manifest, "linux-arm64")
      assert url =~ "/chromium/1193/"
    end

    test "reports clearly when the manifest has no chromium entry at all" do
      assert {:error, {:no_download_for_platform, "linux-arm64"}} =
               Fetcher.find_playwright_url(%{"browsers" => [%{"name" => "firefox", "revision" => "1"}]}, "linux-arm64")
    end
  end

  describe "find_cft_url/2" do
    test "finds the matching platform's URL" do
      assert {:ok, "https://example.test/linux64.zip"} = Fetcher.find_cft_url(@manifest, "linux64")
    end

    test "reports clearly when no download is listed for the platform" do
      assert {:error, {:no_download_for_platform, "linux-arm64"}} = Fetcher.find_cft_url(@manifest, "linux-arm64")
    end
  end
end

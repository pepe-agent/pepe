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
end

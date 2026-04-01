defmodule Pepe.PluginAssetTest do
  use ExUnit.Case, async: false

  alias Pepe.Plugins

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_passet_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  describe "the built-in pepe-widget package" do
    test "declares its assets" do
      assert "widget.js" in Plugins.assets("pepe-widget")
      assert "widget.css" in Plugins.assets("pepe-widget")
    end

    test "resolves a declared asset to its real file" do
      assert {:ok, path} = Plugins.asset_path("pepe-widget", "widget.js")
      assert File.regular?(path)
      assert File.read!(path) =~ "Pepe embeddable chat widget"
    end

    test "the WebSocket URL always carries vsn=2.0.0" do
      # Regression guard: the widget sends V2 array-shaped Phoenix frames
      # ([join_ref, ref, topic, event, payload]). Without ?vsn=2.0.0 on the connect
      # URL, Phoenix falls back to its V1 (map-shaped) serializer and the very first
      # join crashes server-side, silently hanging the widget forever. There is no JS
      # test runner in this project, so this is a plain source-text guard rather than
      # an executed one; keep it in sync with widget.js's wsUrl().
      {:ok, path} = Plugins.asset_path("pepe-widget", "widget.js")
      source = File.read!(path)

      assert source =~ ~r/\/socket\/websocket\?vsn=2\.0\.0/,
             "wsUrl() must always append ?vsn=2.0.0 before any optional &token=..."
    end

    test "refuses a file that exists but isn't declared" do
      assert {:error, :not_found} = Plugins.asset_path("pepe-widget", "manifest.json")
    end

    test "refuses path traversal" do
      assert {:error, :not_found} = Plugins.asset_path("pepe-widget", "../../../../etc/passwd")
    end

    test "refuses an unknown asset name" do
      assert {:error, :not_found} = Plugins.asset_path("pepe-widget", "nope.js")
    end
  end

  test "an unknown plugin name has no assets and resolves nothing" do
    assert Plugins.assets("does-not-exist") == []
    assert {:error, :not_found} = Plugins.asset_path("does-not-exist", "widget.js")
  end

  test "a user-installed package with the same name overrides the built-in one", %{home: home} do
    dir = Path.join([home, "plugins", "pepe-widget"])
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{"assets" => ["custom.js"]}))
    File.write!(Path.join(dir, "custom.js"), "// user override")

    assert Plugins.assets("pepe-widget") == ["custom.js"]
    assert {:ok, path} = Plugins.asset_path("pepe-widget", "custom.js")
    assert File.read!(path) == "// user override"
    # The built-in's own file is no longer reachable once a same-name package is installed.
    assert {:error, :not_found} = Plugins.asset_path("pepe-widget", "widget.js")
  end
end

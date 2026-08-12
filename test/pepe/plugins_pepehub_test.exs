defmodule Pepe.PluginsPepeHubTest do
  @moduledoc """
  Installing a plugin by its PepeHub reference (`@handle/name`) end to end: resolve against
  PepeHub, download the versioned artifact, stage and place it - the same path a real
  `mix pepe plugin install @handle/name` takes.
  """
  use ExUnit.Case, async: false

  defmodule HubPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/api/v1/packages/@jhonathas/backup-tool"} = conn, _opts) do
      json(conn, 200, %{"name" => "@jhonathas/backup-tool", "kind" => "plugin", "official" => false, "latestVersion" => "1.0.0"})
    end

    def call(%{request_path: "/api/v1/packages/@jhonathas/google-workspace"} = conn, _opts) do
      json(conn, 200, %{"name" => "@jhonathas/google-workspace", "kind" => "skill", "official" => false, "latestVersion" => "1.0.0"})
    end

    def call(%{request_path: "/api/v1/packages/@jhonathas/backup-tool/versions/1.0.0/download"} = conn, _opts) do
      send_resp(conn, 200, Elixir.Agent.get(:plugins_pepehub_artifact, & &1))
    end

    def call(conn, _opts), do: json(conn, 404, %{"error" => "not_found"})

    defp json(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_plugins_hub_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    server = start_supervised!({Bandit, plug: HubPlug, port: 0, scheme: :http})
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    base = "http://localhost:#{port}"
    prev_base = Application.get_env(:pepe, :pepe_hub_base_url)
    Application.put_env(:pepe, :pepe_hub_base_url, base)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      if prev_base, do: Application.put_env(:pepe, :pepe_hub_base_url, prev_base), else: Application.delete_env(:pepe, :pepe_hub_base_url)
      File.rm_rf(home)
    end)

    :ok
  end

  defp build_plugin_tgz do
    src = Path.join(System.tmp_dir!(), "pepe_hub_pkg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "manifest.json"), Jason.encode!(%{"name" => "backup-tool"}))

    File.write!(Path.join(src, "backup_tool.exs"), """
    defmodule PepeHubTest.BackupTool do
      def name, do: "backup_tool"
    end
    """)

    tgz = Path.join(System.tmp_dir!(), "pepe_hub_pkg_#{System.unique_integer([:positive])}.tgz")

    files = [
      {~c"manifest.json", File.read!(Path.join(src, "manifest.json"))},
      {~c"backup_tool.exs", File.read!(Path.join(src, "backup_tool.exs"))}
    ]

    :ok = :erl_tar.create(String.to_charlist(tgz), files, [:compressed])
    File.rm_rf(src)
    tgz
  end

  test "installs by @handle/name, naming the plugin from its manifest, not the reference" do
    tgz = build_plugin_tgz()
    {:ok, _} = Elixir.Agent.start_link(fn -> File.read!(tgz) end, name: :plugins_pepehub_artifact)
    on_exit(fn -> File.rm(tgz) end)

    assert {:ok, "backup-tool", scan} = Pepe.Plugins.install("@jhonathas/backup-tool")
    assert scan.verdict == :safe
    assert File.exists?(Path.join(Pepe.Plugins.dir(), "backup-tool/backup_tool.exs"))
  end

  test "installing by the package's own page URL works identically to the shorthand", %{} do
    tgz = build_plugin_tgz()
    {:ok, _} = Elixir.Agent.start_link(fn -> File.read!(tgz) end, name: :plugins_pepehub_artifact)
    on_exit(fn -> File.rm(tgz) end)

    base = Application.get_env(:pepe, :pepe_hub_base_url)
    assert {:ok, "backup-tool", _scan} = Pepe.Plugins.install("#{base}/packages/@jhonathas/backup-tool")
  end

  test "refuses with a clear error when the reference resolves to a skill, not a plugin" do
    assert {:error, {:wrong_kind, "skill"}} = Pepe.Plugins.install("@jhonathas/google-workspace")
    assert Pepe.Plugins.packages() == []
  end

  test "a PepeHub reference that doesn't exist" do
    assert {:error, :not_found} = Pepe.Plugins.install("@jhonathas/nope-#{System.unique_integer([:positive])}")
  end
end

defmodule Pepe.Webhooks.MediaDownloadTest do
  use ExUnit.Case, async: false

  alias Pepe.Webhooks.Media.Download
  alias Pepe.Webhooks.Media.Retention

  defmodule SourcePlug do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    get("/ok", do: Plug.Conn.send_resp(conn, 200, "payload"))
    get("/large", do: Plug.Conn.send_resp(conn, 200, String.duplicate("x", 32)))

    get "/redirect" do
      target = Agent.get(:media_download_state, & &1.target)
      conn |> Plug.Conn.put_resp_header("location", target) |> Plug.Conn.send_resp(302, "")
    end
  end

  defmodule TargetPlug do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    get "/target" do
      send(Agent.get(:media_download_state, & &1.pid), {:authorization, Plug.Conn.get_req_header(conn, "authorization")})
      Plug.Conn.send_resp(conn, 200, "redirected")
    end
  end

  setup do
    test_pid = self()

    start_supervised!(%{
      id: :media_download_state,
      start: {Agent, :start_link, [fn -> %{pid: test_pid, target: nil} end, [name: :media_download_state]]}
    })

    source = start_supervised!({Bandit, plug: SourcePlug, port: 0, startup_log: false})

    target =
      start_supervised!(Supervisor.child_spec({Bandit, plug: TargetPlug, port: 0, startup_log: false}, id: :media_download_target))

    {:ok, {_ip, source_port}} = ThousandIsland.listener_info(source)
    {:ok, {_ip, target_port}} = ThousandIsland.listener_info(target)
    Agent.update(:media_download_state, &%{&1 | target: "http://127.0.0.1:#{target_port}/target"})

    %{base: "http://127.0.0.1:#{source_port}"}
  end

  defp opts(extra \\ []), do: Keyword.merge([schemes: ["http"], check_host: fn _ -> :ok end], extra)

  test "streams a bounded response", %{base: base} do
    assert {:ok, "payload"} = Download.get(base <> "/ok", opts())
    assert {:error, :too_large} = Download.get(base <> "/large", opts(max_bytes: 8))
  end

  test "drops bearer credentials when a redirect changes the port", %{base: base} do
    assert {:ok, "redirected"} = Download.get(base <> "/redirect", opts(bearer: "secret"))
    assert_receive {:authorization, []}
  end

  test "retention removes stale and over-budget files but preserves the current attachment" do
    dir = Path.join(System.tmp_dir!(), "pepe_media_retention_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    old = Path.join(dir, "old")
    keep = Path.join(dir, "keep")
    extra = Path.join(dir, "extra")
    File.write!(old, "old")
    File.write!(keep, "123456")
    File.write!(extra, "123456")
    File.touch!(old, 1)
    File.touch!(extra, 2)
    File.touch!(keep, 3)

    assert Retention.prune(dir, "keep", now: 100, max_age_days: 0, max_total_bytes: 6) == 2
    assert File.read!(keep) == "123456"
    refute File.exists?(old)
    refute File.exists?(extra)
  end
end

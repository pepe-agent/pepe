defmodule Pepe.ACP.McpTest do
  @moduledoc """
  Editor-supplied MCP servers against real servers: a stdio process and HTTP servers on
  loopback. What is pinned here is the *scoping* (a session's servers are its own and end
  with it), the *literal* handling of what an editor sends, and that a server which will not
  start costs the session nothing but a notice.
  """
  use ExUnit.Case, async: false

  alias Pepe.ACP.Mcp
  alias Pepe.Test.MockMCP

  @probe Path.expand("../../support/mock_mcp_probe_server.exs", __DIR__)
  @mock Path.expand("../../support/mock_mcp_server.exs", __DIR__)

  # A remote server that advertises more, and stranger, tools than a model should be handed.
  defmodule ManyToolsPlug do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "initialize", "id" => id} ->
          reply(conn, id, %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "many", "version" => "1"}
          })

        %{"method" => "tools/list", "id" => id} ->
          reply(conn, id, %{"tools" => tools()})

        %{"method" => "tools/call", "id" => id, "params" => %{"name" => name}} ->
          reply(conn, id, %{"content" => [%{"type" => "text", "text" => "ran #{name}"}]})

        _notification ->
          send_resp(conn, 202, "")
      end
    end

    defp reply(conn, id, result) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
    end

    defp tools do
      weird = [
        %{"name" => "weird name!", "description" => "a\u0007b" <> String.duplicate("x", 2000), "inputSchema" => "not a schema"},
        %{
          "name" => "weird name?",
          "description" => "second",
          "inputSchema" => %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}
        }
      ]

      weird ++
        for(n <- 1..70, do: %{"name" => "t#{n}", "description" => "tool #{n}", "inputSchema" => %{"type" => "object", "properties" => %{}}})
    end
  end

  # A remote server whose `big` tool carries a schema far larger than a model should be handed.
  defmodule BigSchemaPlug do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "initialize", "id" => id} ->
          reply(conn, id, %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "big", "version" => "1"}
          })

        %{"method" => "tools/list", "id" => id} ->
          reply(conn, id, %{"tools" => tools()})

        %{"method" => "tools/call", "id" => id, "params" => %{"name" => name}} ->
          reply(conn, id, %{"content" => [%{"type" => "text", "text" => "ran #{name}"}]})

        _notification ->
          send_resp(conn, 202, "")
      end
    end

    defp reply(conn, id, result) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
    end

    defp tools do
      huge = for n <- 1..400, into: %{}, do: {"field_#{n}", %{"type" => "string", "description" => String.duplicate("d", 60)}}

      [
        %{"name" => "big", "description" => "big one", "inputSchema" => %{"type" => "object", "properties" => huge}},
        %{
          "name" => "small",
          "description" => "small one",
          "inputSchema" => %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}
        }
      ]
    end
  end

  defmodule Unauthorized do
    @moduledoc false
    @behaviour Plug

    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 401, "no")
  end

  # Passes every request to the MockMCP server and tells the test what headers came in.
  defmodule HeaderSpy do
    @moduledoc false
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, opts) do
      send(opts[:parent], {:mcp_headers, Map.new(conn.req_headers)})
      MockMCP.call(conn, MockMCP.init(mode: :streamable))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_acp_mcp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    scope = "acp:sess_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> Mcp.detach(scope) end)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, scope: scope}
  end

  defp session(scope, cwd \\ System.tmp_dir!()), do: %{key: scope, cwd: cwd}

  defp stdio(name, script \\ @probe, extra \\ %{}),
    do: Map.merge(%{"name" => name, "command" => "elixir", "args" => [script], "env" => []}, extra)

  defp http_server(plug) do
    {:ok, server} = Bandit.start_link(plug: plug, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp names(specs), do: Enum.map(specs, & &1["function"]["name"])

  # Every editor-supplied client currently running, wherever it was started.
  defp client_pids do
    Pepe.ACP.Mcp.DynSup
    |> PartitionSupervisor.which_children()
    |> Enum.flat_map(fn {_id, partition, _type, _mods} -> DynamicSupervisor.which_children(partition) end)
    |> Enum.map(fn {_id, pid, _type, _mods} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  # A server another test attached and never waited for is still starting in the background;
  # when it lands (and is stopped as an orphan) it must not count as this test's.
  defp settle_earlier_starts, do: eventually(fn -> Task.Supervisor.children(Pepe.MCP.TaskSupervisor) == [] end, 600)

  defp eventually(fun, tries \\ 150) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        receive do
        after
          20 -> eventually(fun, tries - 1)
        end
    end
  end

  describe "a stdio server" do
    test "is offered under an editor namespace, and called in the editor's own project directory", %{scope: scope} do
      project = Path.join(System.tmp_dir!(), "acp_mcp_project_#{System.unique_integer([:positive])}")
      File.mkdir_p!(project)
      on_exit(fn -> File.rm_rf(project) end)

      assert {:ok, %{accepted: ["probe"], rejected: []}} = Mcp.attach(session(scope, project), [stdio("probe")])

      assert [%{"type" => "function", "function" => fun}] = Mcp.specs(scope)
      assert fun["name"] == "mcp__editor_probe__probe"
      assert fun["description"] =~ "editor's MCP server editor_probe"

      assert {:ok, out} = Mcp.call(scope, "mcp__editor_probe__probe", %{})
      assert out =~ "cwd="
      assert out =~ Path.basename(project)
    end

    test "gets its arguments and variables as written: a reference is text, never expanded", %{scope: scope} do
      descriptor = stdio("probe", @probe, %{"args" => [@probe, "${HOME}"], "env" => [%{"name" => "PEPE_PROBE", "value" => "${HOME}"}]})

      assert {:ok, %{accepted: ["probe"]}} = Mcp.attach(session(scope), [descriptor])
      [_spec] = Mcp.specs(scope)

      assert {:ok, out} = Mcp.call(scope, "mcp__editor_probe__probe", %{})
      assert out =~ "argv=${HOME}"
      assert out =~ "env=${HOME}"
      refute out =~ System.get_env("HOME")
    end
  end

  describe "the environment a stdio server starts with" do
    setup do
      System.put_env("PEPE_ACP_SENTINEL", "top-secret-provider-key")
      on_exit(fn -> System.delete_env("PEPE_ACP_SENTINEL") end)
    end

    test "is minimal: Pepe's own variables are invisible to it, its own and PATH are not", %{scope: scope} do
      descriptor = stdio("probe", @probe, %{"env" => [%{"name" => "PEPE_PROBE", "value" => "supplied"}]})

      assert {:ok, %{accepted: ["probe"]}} = Mcp.attach(session(scope), [descriptor])
      [_spec] = Mcp.specs(scope)

      assert {:ok, out} = Mcp.call(scope, "mcp__editor_probe__probe", %{})
      assert out =~ "env=supplied"
      assert out =~ "path=yes"
      assert out =~ "sentinel=none"
      refute out =~ "top-secret-provider-key"
    end

    test "a variable the editor names itself is passed through, even one that shadows Pepe's", %{scope: scope} do
      descriptor = stdio("probe", @probe, %{"env" => [%{"name" => "PEPE_ACP_SENTINEL", "value" => "the editor's own"}]})

      {:ok, _} = Mcp.attach(session(scope), [descriptor])
      [_spec] = Mcp.specs(scope)

      assert {:ok, out} = Mcp.call(scope, "mcp__editor_probe__probe", %{})
      assert out =~ "sentinel=the editor's own"
    end

    test "a server the operator configured keeps the environment it always had" do
      key = {:env_test, System.unique_integer([:positive])}
      sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      spec = %{command: "elixir", args: [@probe], env: %{}}

      # The supervisor is this test's own, so it takes its client down with it.
      assert {:ok, _pid, _module} = Pepe.MCP.start_spec(key, spec, sup)

      assert {:ok, out} = Pepe.MCP.call_running(key, "probe", %{})
      assert out =~ "sentinel=top-secret-provider-key"
    end
  end

  describe "scoping" do
    test "another session sees none of a session's servers and cannot call their tools", %{scope: scope} do
      {:ok, _} = Mcp.attach(session(scope), [stdio("probe")])
      [_] = Mcp.specs(scope)

      assert Mcp.specs("acp:someone-else") == []
      assert {:error, reason} = Mcp.call("acp:someone-else", "mcp__editor_probe__probe", %{})
      assert reason =~ "no editor MCP server"
      assert {:error, _} = Mcp.call(nil, "mcp__editor_probe__probe", %{})
      assert Mcp.specs(nil) == []
    end

    test "the operator's own MCP namespace cannot reach an editor's server", %{scope: scope} do
      {:ok, _} = Mcp.attach(session(scope), [stdio("probe")])
      [_] = Mcp.specs(scope)

      assert {:error, _} = Pepe.MCP.call("mcp__editor_probe__probe", %{})
      assert {:error, _} = Pepe.MCP.call("mcp__probe__probe", %{})
    end

    test "a server exposes only the tools it advertised", %{scope: scope} do
      {:ok, _} = Mcp.attach(session(scope), [stdio("probe")])
      [_] = Mcp.specs(scope)

      assert {:error, reason} = Mcp.call(scope, "mcp__editor_probe__delete_everything", %{})
      assert reason =~ "has no tool"
    end

    test "attaching again replaces the session's servers, and the old ones are stopped", %{scope: scope} do
      {:ok, _} = Mcp.attach(session(scope), [stdio("one")])
      [_] = Mcp.specs(scope)
      [old] = client_pids()
      ref = Process.monitor(old)

      {:ok, _} = Mcp.attach(session(scope), [stdio("two", @mock)])
      assert names(Mcp.specs(scope)) |> Enum.all?(&String.starts_with?(&1, "mcp__editor_two__"))

      assert_receive {:DOWN, ^ref, :process, ^old, _}, 5_000
    end

    test "detaching stops the servers and forgets the session", %{scope: scope} do
      {:ok, _} = Mcp.attach(session(scope), [stdio("probe")])
      [_] = Mcp.specs(scope)
      [pid] = client_pids()
      ref = Process.monitor(pid)

      Mcp.detach(scope)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
      assert Mcp.specs(scope) == []
    end

    test "the servers end with the connection that attached them", %{scope: scope} do
      owner = spawn(fn -> receive do: (:stop -> :ok) end)
      {:ok, _} = Mcp.attach(session(scope), [stdio("probe")], owner: owner)
      [_] = Mcp.specs(scope)
      [pid] = client_pids()
      ref = Process.monitor(pid)

      send(owner, :stop)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
      eventually(fn -> Mcp.specs(scope) == [] end)
    end

    test "a server that died is started once more when it is next called", %{scope: scope} do
      {:ok, _} = Mcp.attach(session(scope), [stdio("probe")])
      [_] = Mcp.specs(scope)
      [pid] = client_pids()
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

      assert {:ok, out} = Mcp.call(scope, "mcp__editor_probe__probe", %{})
      assert out =~ "cwd="
    end
  end

  describe "what a server may put in front of the model" do
    test "a schema too large to pass on is replaced by a bare object, the tool stays callable, and the person is told", %{scope: scope} do
      url = http_server(BigSchemaPlug)
      {:ok, _} = Mcp.attach(session(scope), [%{"type" => "http", "name" => "big", "url" => url <> "/mcp"}])

      specs = Mcp.specs(scope)
      big = Enum.find(specs, &(&1["function"]["name"] == "mcp__editor_big__big"))
      small = Enum.find(specs, &(&1["function"]["name"] == "mcp__editor_big__small"))

      assert big["function"]["parameters"] == %{"type" => "object", "properties" => %{}}
      assert small["function"]["parameters"]["properties"] == %{"q" => %{"type" => "string"}}
      assert byte_size(Jason.encode!(specs)) < 16_384

      assert [note] = Mcp.notices(scope)
      assert note =~ "`big`"
      assert note =~ "too large"

      assert {:ok, "ran big"} = Mcp.call(scope, "mcp__editor_big__big", %{})
    end
  end

  describe "cleaning up after a server that did not finish coming up" do
    test "a client that started but could not list its tools is stopped, not left running for the life of the connection", %{scope: scope} do
      {[server], []} = Pepe.ACP.Mcp.Descriptor.normalize([stdio("probe")], cwd: System.tmp_dir!())
      settle_earlier_starts()
      before = client_pids()
      gen = make_ref()

      assert {:error, {:exception, "error"}} =
               Pepe.ACP.Mcp.Manager.start_server(scope, gen, server,
                 list_tools: fn _module, _pid -> raise "the server stopped answering" end
               )

      assert client_pids() -- before == []
      assert Registry.lookup(Pepe.MCP.Registry, {:acp_mcp, scope, gen, server.ns}) == []
    end

    test "a start that finishes after its session was dropped is stopped, not adopted", %{scope: scope} do
      # `sh` waits a moment before the real server starts, so the detach lands mid-start.
      slow = %{"name" => "slow", "command" => "sh", "args" => ["-c", "sleep 1; exec elixir #{@probe}"], "env" => []}
      settle_earlier_starts()
      before = client_pids()

      {:ok, _} = Mcp.attach(session(scope), [slow])
      Mcp.detach(scope)

      # The start task (and then the stop task it hands the orphan to) are the only work
      # left; once both are done, nothing may still be running for the dropped scope.
      eventually(fn -> Task.Supervisor.children(Pepe.MCP.TaskSupervisor) == [] end, 600)

      assert client_pids() -- before == []
      assert Mcp.specs(scope) == []
    end
  end

  describe "a server that cannot be used" do
    test "one that will not start is reported once and does not stop the others", %{scope: scope} do
      servers = [stdio("gone", @probe, %{"command" => "definitely-not-a-real-binary-xyz"}), stdio("probe")]

      assert {:ok, %{accepted: ["gone", "probe"], rejected: []}} = Mcp.attach(session(scope), servers)

      assert [note] = Mcp.notices(scope)
      assert note =~ "MCP server `gone`"
      assert note =~ "not found on PATH"
      assert note =~ "not available in this session"

      assert Mcp.notices(scope) == []
      assert ["mcp__editor_probe__probe"] = names(Mcp.specs(scope))
    end

    test "a description that is refused is reported with its reason, and the rest is used", %{scope: scope} do
      servers = [%{"name" => "bad", "command" => "./relative"}, stdio("probe")]

      assert {:ok, %{accepted: ["probe"], rejected: [{"bad", reason}]}} = Mcp.attach(session(scope), servers)
      assert reason =~ "absolute path"

      assert [note] = Mcp.notices(scope)
      assert note =~ "`bad`"
      assert note =~ "was not used"
      assert ["mcp__editor_probe__probe"] = names(Mcp.specs(scope))
    end

    test "an unreachable remote server names its host and nothing else about it", %{scope: scope} do
      servers = [
        %{
          "type" => "http",
          "name" => "down",
          "url" => "http://127.0.0.1:1/mcp?token=SECRET",
          "headers" => [%{"name" => "Authorization", "value" => "Bearer SECRET"}]
        }
      ]

      assert {:ok, _} = Mcp.attach(session(scope), servers)
      assert [note] = Mcp.notices(scope)

      assert note =~ "`down` (http://127.0.0.1:1)"
      assert note =~ "could not be reached"
      refute note =~ "SECRET"
    end

    test "a server that answers 401 is told to send an Authorization header", %{scope: scope} do
      url = http_server(Unauthorized)
      {:ok, _} = Mcp.attach(session(scope), [%{"type" => "http", "name" => "locked", "url" => url}])

      assert [note] = Mcp.notices(scope)
      assert note =~ "401"
      assert note =~ "Authorization"
    end

    test "not a list is invalid; nil and [] simply attach nothing", %{scope: scope} do
      assert {:error, :invalid} = Mcp.attach(session(scope), %{"name" => "x"})
      assert {:ok, %{accepted: [], rejected: []}} = Mcp.attach(session(scope), nil)
      assert {:ok, %{accepted: [], rejected: []}} = Mcp.attach(session(scope), [])
      assert Mcp.specs(scope) == []
      assert Mcp.notices(scope) == []
    end
  end

  describe "remote servers" do
    test "an http server is used, and its header values are sent exactly as written", %{scope: scope} do
      url = http_server({HeaderSpy, parent: self()})

      descriptor = %{
        "type" => "http",
        "name" => "docs",
        "url" => url <> "/mcp",
        "headers" => [%{"name" => "X-Api-Key", "value" => "${OPENAI_API_KEY}"}, %{"name" => "X-Plain", "value" => "abc"}]
      }

      assert {:ok, %{accepted: ["docs"]}} = Mcp.attach(session(scope), [descriptor])
      assert ["mcp__editor_docs__boom", "mcp__editor_docs__recall"] = Mcp.specs(scope) |> names() |> Enum.sort()

      assert_receive {:mcp_headers, headers}, 5_000
      assert headers["x-api-key"] == "${OPENAI_API_KEY}"
      assert headers["x-plain"] == "abc"
      refute Map.has_key?(headers, "authorization")

      assert {:ok, out} = Mcp.call(scope, "mcp__editor_docs__recall", %{})
      assert is_binary(out)
    end

    test "a tool that fails in-band comes back as an error, not as a result", %{scope: scope} do
      url = http_server({MockMCP, mode: :streamable})
      {:ok, _} = Mcp.attach(session(scope), [%{"type" => "http", "name" => "docs", "url" => url <> "/mcp"}])
      [_, _] = Mcp.specs(scope)

      assert {:error, _reason} = Mcp.call(scope, "mcp__editor_docs__boom", %{})
    end

    test "a legacy sse server is used when the editor says so", %{scope: scope} do
      url = http_server({MockMCP, mode: :sse})
      {:ok, _} = Mcp.attach(session(scope), [%{"type" => "sse", "name" => "old", "url" => url <> "/sse"}])

      assert "mcp__editor_old__recall" in names(Mcp.specs(scope))
      assert {:ok, _} = Mcp.call(scope, "mcp__editor_old__recall", %{})
    end

    test "what a server advertises is made safe to hand to a model", %{scope: scope} do
      url = http_server(ManyToolsPlug)
      {:ok, _} = Mcp.attach(session(scope), [%{"type" => "http", "name" => "many", "url" => url}])

      specs = Mcp.specs(scope)
      names = names(specs)

      assert Enum.count_until(specs, 65) == 64
      assert Enum.count_until(Enum.uniq(names), 65) == 64
      assert Enum.all?(names, &Regex.match?(~r/^[A-Za-z0-9_-]+$/, &1))

      weird = Enum.find(specs, &(&1["function"]["name"] == "mcp__editor_many__weird_name_"))
      refute weird["function"]["description"] =~ <<7>>
      assert String.length(weird["function"]["description"]) <= 1024 + 80
      assert weird["function"]["parameters"] == %{"type" => "object", "properties" => %{}}

      assert [note] = Mcp.notices(scope)
      assert note =~ "72 tools"
      assert note =~ "first 64"

      # The rewritten name still reaches the tool under its own, original name.
      assert {:ok, "ran weird name!"} = Mcp.call(scope, "mcp__editor_many__weird_name_", %{})
      assert {:ok, "ran weird name?"} = Mcp.call(scope, "mcp__editor_many__weird_name__2", %{})
    end
  end
end

defmodule Pepe.Agent.BashWorkspaceCwdTest do
  # Regression: through a real one-shot (the `mix pepe run` path), a `bash` tool
  # call must run in the agent's workspace - the same place read_file/write_file
  # resolve relative paths - not wherever the OS process happened to be started
  # from. Nothing on the CLI path ever passed `:cwd`, so bash used to fall back
  # to `File.cwd!()` and a `cat reports/messy.csv` failed even though the file
  # existed in the workspace.
  use ExUnit.Case, async: false

  defmodule BashMock do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      last = body |> Jason.decode!() |> Map.fetch!("messages") |> List.last()

      message =
        if last["role"] == "tool" do
          %{"role" => "assistant", "content" => "TOOL SAID: #{last["content"]}"}
        else
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{
                  "name" => "bash",
                  "arguments" => ~s({"command":"cat reports/messy.csv"})
                }
              }
            ]
          }
        end

      resp = %{
        "id" => "x",
        "object" => "chat.completion",
        "choices" => [
          %{
            "index" => 0,
            "message" => message,
            "finish_reason" => if(message["tool_calls"], do: "tool_calls", else: "stop")
          }
        ]
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(resp))
    end
  end

  test "a one-shot bash call resolves relative paths in the agent's workspace, not the OS cwd" do
    home = Path.join(System.tmp_dir!(), "pepe_bash_cwd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, _} = Application.ensure_all_started(:req)
    server = start_supervised!({Bandit, plug: BashMock, port: 0, scheme: :http})
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Pepe.Config.put_model(%Pepe.Config.Model{
      name: "mock",
      base_url: "http://localhost:#{port}",
      api_key: "test",
      model: "mock-model"
    })

    Pepe.Config.put_agent(%Pepe.Config.Agent{
      name: "bench",
      model: "mock",
      system_prompt: "bench agent",
      tools: ["bash"],
      max_iterations: 3
    })

    # The file lives ONLY in the agent's workspace; the test process's own cwd
    # (the repo root) has no reports/ directory, so the old File.cwd!() fallback
    # would make `cat reports/messy.csv` fail with "No such file or directory".
    workspace = Pepe.Agent.Workspace.dir("bench")
    File.mkdir_p!(Path.join(workspace, "reports"))
    File.write!(Path.join(workspace, "reports/messy.csv"), "a,b\n1,2\n")
    refute File.exists?("reports/messy.csv")

    events = self()

    # Same shape as the CLI's `mix pepe run` call: no :cwd anywhere in opts.
    {:ok, content, _messages} =
      Pepe.Agent.oneshot("bench", "please process the report",
        authorize: fn _name, _args, _ctx -> :this_run end,
        on_event: fn
          {:tool_result, "bash", out} -> send(events, {:bash_result, out})
          _ -> :ok
        end
      )

    assert_received {:bash_result, out}
    assert out =~ "exit_status=0"
    assert out =~ "a,b"
    refute out =~ "No such file or directory"
    assert content =~ "a,b"
  end
end

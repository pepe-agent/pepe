defmodule Pepe.Agent.RuntimeDenyReasonTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Runtime
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.LLM.Message
  alias Pepe.Permissions

  # A mock model that always asks to run `bash` once, then wraps up once it
  # sees the tool's result come back.
  defmodule BashPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      last = body |> Jason.decode!() |> Map.fetch!("messages") |> List.last()

      message =
        if last["role"] == "tool" do
          %{"role" => "assistant", "content" => "ok, moving on"}
        else
          tool_call = %{
            "id" => "call_1",
            "type" => "function",
            "function" => %{"name" => "bash", "arguments" => ~s({"command":"rm -rf /tmp/x"})}
          }

          %{"role" => "assistant", "content" => nil, "tool_calls" => [tool_call]}
        end

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => message, "finish_reason" => if(last["role"] == "tool", do: "stop", else: "tool_calls")}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_rdeny_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, server} = Bandit.start_link(plug: BashPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    model = %Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"}
    agent = %Agent{name: "denier", model: "mock", tools: ["bash"], max_iterations: 5}

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, agent: agent, model: model}
  end

  test "a deny with a reason reaches the model's tool-result content", %{agent: agent, model: model} do
    authorize = fn _name, _args, _ctx -> {:deny, "not now, budget's tight"} end
    test_pid = self()
    on_event = fn ev -> send(test_pid, {:runtime_event, ev}) end

    messages = [Message.system("you are a test agent"), Message.user("run bash")]

    {:ok, _final, all_messages} =
      Runtime.run(agent, messages, model: model, authorize: authorize, on_event: on_event)

    tool_result = Enum.find(all_messages, &(&1["role"] == "tool"))
    content = tool_result["content"]

    assert content == Permissions.denied_message("bash", "not now, budget's tight")
    assert_received {:runtime_event, {:tool_denied, "bash", "not now, budget's tight"}}
  end
end

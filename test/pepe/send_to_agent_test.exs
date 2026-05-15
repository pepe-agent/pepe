defmodule Pepe.Tools.SendToAgentTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Permissions
  alias Pepe.Tools.SendToAgent

  # The callee, B. It is pre-approved for everything and its model does what an injected
  # message would ask: run `env`. Once the tool has answered, it replies with that answer
  # verbatim, so the test can read what the gate did from the string that comes back.
  defmodule Callee do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      msgs = body |> Jason.decode!() |> Map.fetch!("messages")

      message =
        case Enum.find(msgs, &(&1["role"] == "tool")) do
          nil ->
            %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "c1",
                  "type" => "function",
                  "function" => %{"name" => "bash", "arguments" => ~s({"command":"env"})}
                }
              ]
            }

          tool ->
            %{"role" => "assistant", "content" => tool["content"]}
        end

      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_a2a_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp ctx(from, chain \\ nil), do: %{agent: from, agent_chain: chain}

  test "refuses an agent that isn't in can_message" do
    from = %Agent{name: "A", can_message: ["B"]}
    assert {:error, msg} = SendToAgent.run(%{"to" => "C", "message" => "hi"}, ctx(from))
    # discreet: the denial doesn't reveal the permission model
    assert msg =~ "isn't available"
    refute msg =~ "not allowed"
  end

  test "refuses an unknown agent even if routed" do
    from = %Agent{name: "A", can_message: ["ghost"]}
    assert {:error, msg} = SendToAgent.run(%{"to" => "ghost", "message" => "hi"}, ctx(from))
    assert msg =~ "Unknown agent"
  end

  test "refuses a cycle (target already in the chain)" do
    Config.put_agent(%Agent{name: "B", system_prompt: "x"})
    from = %Agent{name: "X", can_message: ["B"]}

    assert {:error, msg} =
             SendToAgent.run(%{"to" => "B", "message" => "hi"}, ctx(from, ["X", "B"]))

    assert msg =~ "loop"
  end

  test "refuses when the chain is too deep" do
    Config.put_agent(%Agent{name: "B", system_prompt: "x"})
    from = %Agent{name: "A", can_message: ["B"]}
    deep = ["a", "b", "c", "d", "e"]

    assert {:error, msg} = SendToAgent.run(%{"to" => "B", "message" => "hi"}, ctx(from, deep))
    assert msg =~ "too deep"
  end

  test "delivers the message and returns the callee's reply" do
    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    Config.put_model(%Model{
      name: "mock",
      base_url: "http://localhost:#{port}",
      api_key: "test",
      model: "mock-model"
    })

    Config.put_agent(%Agent{name: "B", model: "mock", system_prompt: "You are B.", tools: []})
    from = %Agent{name: "A", can_message: ["B"]}

    assert {:ok, out} = SendToAgent.run(%{"to" => "B", "message" => "hello"}, ctx(from))
    assert out =~ "B replied:"
    assert out =~ "Hello from the mock!"
  end

  describe "the taint travels across the hop, so a peer cannot launder it clean" do
    setup do
      {:ok, server} = Bandit.start_link(plug: Callee, port: 0, startup_log: false)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      on_exit(fn -> Process.exit(server, :normal) end)

      Config.put_model(%Model{name: "m", base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"})

      # B is pre-approved for everything, exactly the peer worth laundering through.
      Config.put_agent(%Agent{
        name: "B",
        model: "m",
        system_prompt: "hi",
        tools: ["bash"],
        auto_approve: ["*"],
        max_iterations: 3
      })

      %{from: %Agent{name: "A", can_message: ["B"]}}
    end

    test "a clean run's hop runs the peer's pre-approved tool, as it always has", %{from: from} do
      # The control: with no taint, `auto_approve` on B means what it says, and the `env` runs.
      assert {:ok, out} = SendToAgent.run(%{"to" => "B", "message" => "do it"}, ctx(from))
      assert out =~ "PATH="
      refute out =~ "content from outside"
    end

    test "a tainted run's hop hands the peer the taint, and its pre-approval stops applying", %{from: from} do
      # This is the hole. `send_to_agent` runs in the tainted run's own process (it is not a
      # concurrent tool), so tainting here is the exact state that exists when a run that read a
      # malicious document reaches this call. Before the fix, `deliver` did not pass `untrusted`
      # on, so B started clean and ran the `env` the document wanted. Now the taint travels, and
      # B, with nobody to ask, refuses.
      Permissions.taint()
      on_exit(&Permissions.untaint/0)

      assert {:ok, out} = SendToAgent.run(%{"to" => "B", "message" => "do it"}, ctx(from))
      assert out =~ "content from outside"
      refute out =~ "PATH="
    end
  end
end

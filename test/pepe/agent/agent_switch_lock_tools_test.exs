defmodule Pepe.Agent.AgentSwitchLockToolsTest do
  @moduledoc """
  `agent_switch_locked` doesn't just refuse switch_agent/manage_channel's bind_topic at call
  time - it keeps the model from ever being offered the locked-out capability in the first
  place (see Pepe.Agent.Runtime.run_chain/3's hide_switch_agent/2), so a locked turn never
  spends tokens describing, or a call refusing, a tool the model was never going to be
  allowed to use.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Runtime
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # A model that reports back exactly what tools it was offered, and the manage_channel
  # `action` enum specifically, so the test can see what the request actually declared.
  defmodule ToolsPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)
      names = (req["tools"] || []) |> Enum.map(& &1["function"]["name"]) |> Enum.sort()

      manage_channel_actions =
        Enum.find_value(req["tools"] || [], fn
          %{"function" => %{"name" => "manage_channel"} = fun} ->
            get_in(fun, ["parameters", "properties", "action", "enum"])

          _ ->
            nil
        end)

      content = Jason.encode!(%{"tools" => names, "manage_channel_actions" => manage_channel_actions})
      message = %{"role" => "assistant", "content" => content}
      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_switchlock_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, server} = Bandit.start_link(plug: ToolsPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "m", base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"})

    agent = %Agent{
      name: "worker",
      model: "m",
      system_prompt: "hi",
      tools: ["switch_agent", "manage_channel"],
      # switch_agent is only offered to an agent that has someone to hand a conversation to.
      can_message: ["peer"],
      auto_approve: ["*"],
      max_iterations: 2
    }

    Config.put_agent(agent)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{agent: agent, cwd: home}
  end

  test "unlocked: both tools are offered in full, manage_channel keeps every action", %{agent: agent, cwd: cwd} do
    {:ok, reply, _} = Runtime.converse(agent, "hi", cwd: cwd, agent_switch_locked: false)
    decoded = Jason.decode!(reply)

    assert decoded["tools"] == ["manage_channel", "switch_agent"]
    assert "bind_topic" in decoded["manage_channel_actions"]
    assert "unbind_topic" in decoded["manage_channel_actions"]
  end

  test "locked: switch_agent is hidden outright, manage_channel loses only bind_topic/unbind_topic", %{
    agent: agent,
    cwd: cwd
  } do
    {:ok, reply, _} = Runtime.converse(agent, "hi", cwd: cwd, agent_switch_locked: true)
    decoded = Jason.decode!(reply)

    refute "switch_agent" in decoded["tools"]
    assert decoded["tools"] == ["manage_channel"]
    refute "bind_topic" in decoded["manage_channel_actions"]
    refute "unbind_topic" in decoded["manage_channel_actions"]
    # Every other action is untouched - the lock only ever removes these two.
    assert "list" in decoded["manage_channel_actions"]
    assert "set_trainers" in decoded["manage_channel_actions"]
  end
end

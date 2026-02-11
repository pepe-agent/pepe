defmodule CortexWeb.WatchWsDeliveryTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias Cortex.Config
  alias Cortex.Config.Watch
  alias Cortex.Watch.Scheduler

  @endpoint CortexWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:cortex)

    home = Path.join(System.tmp_dir!(), "cortex_wsdel_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)

    config = %{
      "default_agent" => "assistant",
      "agents" => %{"assistant" => %{"system_prompt" => "hi", "tools" => []}}
    }

    File.write!(Path.join(home, "config.json"), Jason.encode!(config))
    start_supervised!(Scheduler)

    on_exit(fn ->
      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "a watch created from a ws session is pushed back to that session when it fires" do
    {:ok, socket} = connect(CortexWeb.AgentSocket, %{})
    {:ok, _reply, _socket} = subscribe_and_join(socket, "agent:default", %{"session" => "sess1"})

    Config.put_watch(%Watch{
      id: "w1",
      description: "deploy",
      interval_s: 120,
      trigger: %{"type" => "probe", "command" => "exit 0"},
      on_fire: %{"type" => "template", "text" => "deploy done"},
      origin: %{"channel" => "ws", "key" => "ws:sess1"}
    })

    send(Scheduler, :tick)

    assert_push "watch", %{text: "deploy done"}, 2_000
    assert Config.get_watch("w1").state == "done"
  end
end

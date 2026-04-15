defmodule PepeWeb.AgentChannelHistoryTest do
  @moduledoc """
  The join reply carries prior history for an already-live session, so a client
  that lost its own in-memory transcript (e.g. a page reload) can rehydrate it
  instead of looking like the conversation was lost.
  """
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    home = Path.join(System.tmp_dir!(), "pepe_ach_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Config.Model{
      name: "mock",
      base_url: "http://localhost:#{port}",
      api_key: "x",
      model: "mock-model"
    })

    Config.put_agent(%Config.Agent{name: "assistant", system_prompt: "hi", tools: [], model: "mock"})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "a fresh session's join reply carries an empty history" do
    {:ok, socket} = connect(PepeWeb.AgentSocket, %{}, connect_info: %{peer_data: %{address: {127, 0, 0, 1}}})
    session = "hist-#{System.unique_integer([:positive])}"

    assert {:ok, %{history: []}, _socket} = subscribe_and_join(socket, "agent:assistant", %{"session" => session})
  end

  test "rejoining an already-live session's join reply carries its prior turns" do
    session = "hist-#{System.unique_integer([:positive])}"

    {:ok, socket1} = connect(PepeWeb.AgentSocket, %{}, connect_info: %{peer_data: %{address: {127, 0, 0, 1}}})
    {:ok, _reply, socket1} = subscribe_and_join(socket1, "agent:assistant", %{"session" => session})

    push(socket1, "prompt", %{"text" => "hello"})
    assert_push "done", %{content: "Hello from the mock!"}, 2_000

    {:ok, socket2} = connect(PepeWeb.AgentSocket, %{}, connect_info: %{peer_data: %{address: {127, 0, 0, 1}}})
    assert {:ok, %{history: history}, _socket} = subscribe_and_join(socket2, "agent:assistant", %{"session" => session})

    assert %{role: "user", content: "hello"} in history
    assert Enum.any?(history, &(&1.role == "assistant" and &1.content == "Hello from the mock!"))
  end
end

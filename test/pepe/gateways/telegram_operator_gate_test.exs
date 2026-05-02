defmodule Pepe.Gateways.TelegramOperatorGateTest do
  @moduledoc """
  The operator gate, exercised through the real poll/dispatch/reply path against a mock
  Telegram API.

  This is a security net, not a unit test. On a customer-facing bot (one with a
  `trainers` allowlist) a client must never reach config, permissions, spend, internal
  inventory, or a skill. The regression it exists to catch: every installed skill also
  becomes a top-level command, so `/skill install-tool` and `/install-tool` are two paths
  to the same place, and gating only the first leaves the second wide open.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Gateways.Telegram

  @trainer 111
  @client 999
  @chat 555

  @refusal "That command isn't available here."

  # Serves the three endpoints the gateway touches. `getUpdates` hands out each queued
  # update exactly once, then goes quiet; every `sendMessage` is forwarded to the test.
  defmodule MockPlug do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:dispatch)

    get "/bot:token/getUpdates" do
      updates = Agent.get_and_update(:tg_gate_updates, &{&1, []})
      # Nothing pending: idle briefly instead of spinning the poller hot.
      if updates == [], do: Process.sleep(20)
      json(conn, %{"ok" => true, "result" => updates})
    end

    post "/bot:token/sendMessage" do
      send(Agent.get(:tg_gate_test_pid, & &1), {:sent, conn.body_params["text"] || ""})
      json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
    end

    match _ do
      json(conn, %{"ok" => true, "result" => true})
    end

    defp json(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tg_gate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    # A user skill, which is also what makes `/deploy_thing` a command in its own right.
    File.write!(Path.join([home, "skills", "deploy-thing.md"]), "# Deploy\n\nHow to deploy.\n")

    test_pid = self()
    {:ok, _} = Agent.start_link(fn -> [] end, name: :tg_gate_updates)
    {:ok, _} = Agent.start_link(fn -> test_pid end, name: :tg_gate_test_pid)

    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    prev_base = Application.get_env(:pepe, :telegram_api_base)
    Application.put_env(:pepe, :telegram_api_base, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      if prev_base,
        do: Application.put_env(:pepe, :telegram_api_base, prev_base),
        else: Application.delete_env(:pepe, :telegram_api_base)

      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  # A customer-facing bot: `trainers` names who is trusted, so everyone else is a client.
  defp start_bot! do
    bot = %{
      "name" => "default",
      "bot_token" => "test-token",
      "agent" => "assistant",
      "trainers" => [@trainer]
    }

    Config.put_telegram(bot)
    start_supervised!(%{id: Telegram, start: {Telegram, :start_link, [bot]}})
    :ok
  end

  defp send_command(user_id, text) do
    update = %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "text" => text,
        "chat" => %{"id" => @chat, "type" => "private"},
        "from" => %{"id" => user_id}
      }
    }

    Agent.update(:tg_gate_updates, &(&1 ++ [update]))
  end

  defp await_reply do
    assert_receive {:sent, text}, 5_000
    text
  end

  describe "a client on a customer-facing bot" do
    setup do: start_bot!()

    test "is refused a skill invoked by its own command name" do
      # The whole point: /deploy_thing is the same door as /skill deploy-thing.
      send_command(@client, "/deploy_thing")
      assert await_reply() =~ @refusal
    end

    test "is refused a skill invoked through /skill" do
      send_command(@client, "/skill deploy-thing")
      assert await_reply() =~ @refusal
    end

    for cmd <- ~w(agent status models tools skill approve usage) do
      test "is refused /#{cmd}" do
        send_command(@client, "/#{unquote(cmd)}")
        assert await_reply() =~ @refusal
      end
    end

    test "is refused /model when it would reveal which model is configured" do
      send_command(@client, "/model")
      assert await_reply() =~ @refusal
    end

    test "is never even shown an operator command in /help" do
      send_command(@client, "/help")
      help = await_reply()

      # Match how the menu renders a command ("/name - description"), not a bare
      # substring: "/skill" also occurs inside "/learn - Save what I learned to
      # memory/skills", where a naive refute would pass for the wrong reason.
      for cmd <- ~w(usage approve skill agent status models tools deploy_thing) do
        refute help =~ "/#{cmd} -"
      end

      # ...while what they can actually run is still listed.
      assert help =~ "/new -"
      assert help =~ "/help -"
    end
  end

  describe "a trainer on the same bot" do
    setup do: start_bot!()

    test "reaches an operator command" do
      send_command(@trainer, "/status")
      reply = await_reply()

      refute reply =~ @refusal
      assert reply =~ "Agent:"
    end

    test "sees operator commands listed in /help" do
      send_command(@trainer, "/help")
      help = await_reply()

      assert help =~ "/usage"
      assert help =~ "/deploy_thing"
    end
  end
end

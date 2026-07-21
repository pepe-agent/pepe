defmodule Pepe.Gateways.TelegramDeliveryLedgerTest do
  @moduledoc """
  The boot-time half of the delivery ledger: a bot that starts up with a reply still
  owed from before it last went down redelivers it before doing anything else, marking
  an ambiguous one (crashed mid-send, or was rejected) as possibly a duplicate, and
  leaving a plainly-never-sent one to go out clean. A row belonging to some other bot
  (or already delivered) is left alone.

  The obligations here are written directly via `Pepe.DeliveryLedger`, standing in for
  "a previous boot got this far and then died" - the same state a real crash mid-send
  would leave behind.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.DeliveryLedger
  alias Pepe.Gateways.Telegram

  defmodule MockPlug do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:dispatch)

    get "/bot:token/getUpdates" do
      Process.sleep(20)
      json(conn, %{"ok" => true, "result" => []})
    end

    get "/bot:token/getMe" do
      json(conn, %{"ok" => true, "result" => %{"username" => "pepebot"}})
    end

    post "/bot:token/sendMessage" do
      send(test_pid(), {:sent, conn.body_params["chat_id"], conn.body_params["text"] || ""})
      json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
    end

    match _ do
      json(conn, %{"ok" => true, "result" => true})
    end

    defp test_pid, do: safe(fn -> Agent.get(:tg_ledger_test_pid, & &1) end, self())

    defp safe(fun, default) do
      fun.()
    catch
      :exit, _ -> default
    end

    defp json(conn, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tg_ledger_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    test_pid = self()
    {:ok, _} = Agent.start_link(fn -> test_pid end, name: :tg_ledger_test_pid)

    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"

    prev_base = Application.get_env(:pepe, :telegram_api_base)
    Application.put_env(:pepe, :telegram_api_base, base)

    chat = 9_900_000 + System.unique_integer([:positive])

    on_exit(fn ->
      if prev_base,
        do: Application.put_env(:pepe, :telegram_api_base, prev_base),
        else: Application.delete_env(:pepe, :telegram_api_base)

      :mnesia.stop()
      :persistent_term.erase({Pepe.Store, :ready})
      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, chat: chat}
  end

  defp start_bot!(extra \\ %{}) do
    bot = Map.merge(%{"name" => "default", "bot_token" => "t", "agent" => "assistant"}, extra)
    Config.put_telegram(bot)
    start_supervised!(%{id: Telegram, start: {Telegram, :start_link, [bot]}})
    :ok
  end

  test "a reply that never even started sending goes out clean on the next boot", %{chat: chat} do
    DeliveryLedger.record("telegram:#{chat}", "telegram", %{bot: "default", chat_id: chat, thread_id: nil}, "still owed")
    refute_receive {:sent, ^chat, "still owed"}, 100

    start_bot!()

    # Exactly the plain content, no recovered marker - the send never even started before
    # the previous boot went away, so there is no ambiguity to flag.
    assert_receive {:sent, ^chat, "still owed"}, 2_000
  end

  test "a reply stuck mid-send carries the recovered marker on redelivery", %{chat: chat} do
    id = DeliveryLedger.record("telegram:#{chat}", "telegram", %{bot: "default", chat_id: chat, thread_id: nil}, "half sent")
    DeliveryLedger.mark_attempting(id)

    start_bot!()

    assert_receive {:sent, ^chat, text}, 2_000
    assert text =~ "Recovered reply"
    assert text =~ "half sent"
  end

  test "a definitively failed reply is also redelivered with the marker", %{chat: chat} do
    id = DeliveryLedger.record("telegram:#{chat}", "telegram", %{bot: "default", chat_id: chat, thread_id: nil}, "rejected once")
    DeliveryLedger.mark_attempting(id)
    DeliveryLedger.mark_failed(id, "http 400")

    start_bot!()

    assert_receive {:sent, ^chat, text}, 2_000
    assert text =~ "Recovered reply"
    assert text =~ "rejected once"
  end

  test "an already-delivered reply is never resent", %{chat: chat} do
    id = DeliveryLedger.record("telegram:#{chat}", "telegram", %{bot: "default", chat_id: chat, thread_id: nil}, "already done")
    DeliveryLedger.mark_attempting(id)
    DeliveryLedger.mark_delivered(id)

    start_bot!()

    refute_receive {:sent, ^chat, "already done"}, 500
  end

  test "a row belonging to a different bot name is left for that bot, not sent by this one", %{chat: chat} do
    DeliveryLedger.record("telegram:someone-else:#{chat}", "telegram", %{bot: "someone-else", chat_id: chat, thread_id: nil}, "not mine")

    start_bot!()

    refute_receive {:sent, ^chat, "not mine"}, 500
  end
end

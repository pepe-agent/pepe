defmodule Pepe.Gateways.TelegramQuickReactionsTest do
  @moduledoc """
  The zero-token quick-reaction fast path: a message that's only a thank-you or a bare
  emoji gets a native reaction, with no call to the model at all. Driven through the real
  poll/dispatch path against a mock Telegram API, same style as telegram_commands_test.exs.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Gateways.Telegram

  @user 42

  defmodule MockPlug do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:dispatch)

    get "/bot:token/getUpdates" do
      updates = safe_take(:tg_qr_updates, [])
      if updates == [], do: Process.sleep(20)
      json(conn, %{"ok" => true, "result" => updates})
    end

    get "/bot:token/getMe" do
      json(conn, %{"ok" => true, "result" => %{"username" => "pepebot"}})
    end

    post "/bot:token/sendMessage" do
      send(test_pid(), {:sent, conn.body_params["chat_id"], conn.body_params["text"] || ""})
      json(conn, %{"ok" => true, "result" => %{"message_id" => 777}})
    end

    post "/bot:token/setMessageReaction" do
      send(test_pid(), {:reaction, conn.body_params["chat_id"], conn.body_params["reaction"]})
      json(conn, %{"ok" => true, "result" => true})
    end

    post "/chat/completions" do
      send(test_pid(), :llm_called)

      json(conn, %{
        "id" => "x",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "here is my answer"}, "finish_reason" => "stop"}]
      })
    end

    match _ do
      json(conn, %{"ok" => true, "result" => true})
    end

    defp safe_take(name, default) do
      if Process.whereis(name), do: Agent.get_and_update(name, &{&1, default}), else: default
    end

    defp test_pid, do: Agent.get(:tg_qr_test_pid, & &1)
    defp json(conn, data), do: conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(data))
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tg_qr_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    test_pid = self()
    {:ok, _} = Agent.start_link(fn -> [] end, name: :tg_qr_updates)
    {:ok, _} = Agent.start_link(fn -> test_pid end, name: :tg_qr_test_pid)

    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"

    prev_base = Application.get_env(:pepe, :telegram_api_base)
    Application.put_env(:pepe, :telegram_api_base, base)

    chat = 8_900_000 + System.unique_integer([:positive])

    Config.put_model(%Model{name: "mock", base_url: base, api_key: "k", model: "mock-model"})
    Config.put_agent(%Pepe.Config.Agent{name: "assistant", model: "mock", system_prompt: "You help.", tools: []})

    on_exit(fn ->
      if prev_base, do: Application.put_env(:pepe, :telegram_api_base, prev_base), else: Application.delete_env(:pepe, :telegram_api_base)
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

  defp push(message), do: Agent.update(:tg_qr_updates, &(&1 ++ [message]))

  defp say(chat, text) do
    push(%{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "text" => text,
        "chat" => %{"id" => chat, "type" => "private"},
        "from" => %{"id" => @user}
      }
    })
  end

  test "off by default: a thank-you still gets a normal reply", %{chat: chat} do
    start_bot!()
    say(chat, "obrigado!")

    assert_receive :llm_called, 5_000
    assert_receive {:sent, ^chat, "here is my answer"}, 5_000
  end

  test "enabled: a bare thank-you gets a reaction, no model call", %{chat: chat} do
    start_bot!(%{"quick_reactions" => true})
    say(chat, "valeu!")

    assert_receive {:reaction, ^chat, [%{"emoji" => emoji}]}, 5_000
    assert emoji in ["🔥", "❤️"]
    refute_receive :llm_called, 300
  end

  test "enabled: a bare emoji message gets echoed back as a reaction", %{chat: chat} do
    start_bot!(%{"quick_reactions" => true})
    say(chat, "🙏")

    assert_receive {:reaction, ^chat, [%{"emoji" => "🙏"}]}, 5_000
    refute_receive :llm_called, 300
  end

  test "enabled: a real question still goes to the model, even a short one", %{chat: chat} do
    start_bot!(%{"quick_reactions" => true})
    say(chat, "obrigado, mas ainda tenho uma duvida")

    assert_receive :llm_called, 5_000
    assert_receive {:sent, ^chat, "here is my answer"}, 5_000
  end
end

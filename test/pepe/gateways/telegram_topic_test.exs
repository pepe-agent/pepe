defmodule Pepe.Gateways.TelegramTopicTest do
  @moduledoc """
  A message in a forum topic, end to end: the reply must be sent back INTO that topic
  (`message_thread_id`), not into General. Drives the real gateway against a Telegram mock
  and inspects the outgoing `sendMessage`.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent, as: AgentCfg
  alias Pepe.Config.Model
  alias Pepe.Gateways.Telegram

  @user 55

  defmodule MockPlug do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:dispatch)

    get "/bot:token/getUpdates" do
      json(conn, %{"ok" => true, "result" => take(:tg_topic_updates, [])})
    end

    get "/bot:token/getMe" do
      json(conn, %{"ok" => true, "result" => %{"username" => "pepebot"}})
    end

    post "/bot:token/sendMessage" do
      # Capture the thread the reply was routed into (nil = General / no topic).
      send(test_pid(), {:sent, conn.body_params["text"], conn.body_params["message_thread_id"]})
      json(conn, %{"ok" => true, "result" => %{"message_id" => System.unique_integer([:positive])}})
    end

    post "/chat/completions" do
      json(conn, %{
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => "here you go"}, "finish_reason" => "stop"}
        ]
      })
    end

    match _ do
      json(conn, %{"ok" => true, "result" => true})
    end

    defp test_pid, do: read(:tg_topic_test_pid, self())
    defp read(name, default), do: safe(fn -> Elixir.Agent.get(name, & &1) end, default)
    defp take(name, default), do: safe(fn -> Elixir.Agent.get_and_update(name, &{&1, []}) end, default)

    defp safe(fun, default) do
      fun.()
    catch
      :exit, _ -> default
    end

    defp json(conn, body),
      do: conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tg_topic_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    test_pid = self()
    {:ok, _} = Elixir.Agent.start_link(fn -> [] end, name: :tg_topic_updates)
    {:ok, _} = Elixir.Agent.start_link(fn -> test_pid end, name: :tg_topic_test_pid)

    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"

    prev_base = Application.get_env(:pepe, :telegram_api_base)
    Application.put_env(:pepe, :telegram_api_base, base)

    Config.put_model(%Model{name: "mock", base_url: base, api_key: "k", model: "m"})
    Config.put_agent(%AgentCfg{name: "assistant", model: "mock", system_prompt: "hi", tools: [], max_iterations: 2})

    on_exit(fn ->
      if prev_base,
        do: Application.put_env(:pepe, :telegram_api_base, prev_base),
        else: Application.delete_env(:pepe, :telegram_api_base)

      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{chat: -1_000_000 - System.unique_integer([:positive])}
  end

  defp start_bot! do
    # require_mention false so a plain topic message is answered without an @mention.
    bot = %{"name" => "default", "bot_token" => "t", "agent" => "assistant", "require_mention" => false}
    Config.put_telegram(bot)
    start_supervised!(%{id: Telegram, start: {Telegram, :start_link, [bot]}})
    :ok
  end

  defp queue_text(chat, text, opts) do
    update = %{
      "update_id" => System.unique_integer([:positive]),
      "message" =>
        %{
          "message_id" => System.unique_integer([:positive]),
          "chat" => %{"id" => chat, "type" => opts[:chat_type] || "supergroup"},
          "from" => %{"id" => @user},
          "text" => text
        }
        |> then(fn m -> if opts[:thread], do: Map.put(m, "message_thread_id", opts[:thread]), else: m end)
    }

    Elixir.Agent.update(:tg_topic_updates, &(&1 ++ [update]))
  end

  test "a reply to a message in a topic is sent back into that topic", %{chat: chat} do
    start_bot!()
    queue_text(chat, "oi", thread: 99)

    assert_receive {:sent, "here you go", thread}, 5_000
    assert thread == 99
  end

  test "a reply in General (no topic) carries no message_thread_id", %{chat: chat} do
    start_bot!()
    queue_text(chat, "oi", thread: nil)

    assert_receive {:sent, "here you go", thread}, 5_000
    assert thread == nil
  end
end

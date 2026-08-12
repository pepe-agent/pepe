defmodule Pepe.Gateways.TelegramSenderTagTest do
  @moduledoc """
  A group or topic can have several different people talking to the same bot in the same
  session - the text handed to the model must say who sent it, or the agent has no way to
  tell them apart (and ends up addressing everyone by whichever name it saw first). A
  private chat has exactly one person on the other end, so it must NOT be tagged.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent, as: AgentCfg
  alias Pepe.Config.Model
  alias Pepe.Gateways.Telegram

  defmodule MockPlug do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:dispatch)

    get "/bot:token/getUpdates" do
      json(conn, %{"ok" => true, "result" => take(:tg_sender_tag_updates, [])})
    end

    get "/bot:token/getMe" do
      json(conn, %{"ok" => true, "result" => %{"username" => "pepebot"}})
    end

    post "/bot:token/sendMessage" do
      json(conn, %{"ok" => true, "result" => %{"message_id" => System.unique_integer([:positive])}})
    end

    post "/chat/completions" do
      user_contents =
        conn.body_params["messages"]
        |> Enum.filter(&(&1["role"] == "user"))
        |> Enum.map(& &1["content"])

      send(test_pid(), {:model_saw, List.last(user_contents)})
      send(test_pid(), {:model_saw_all_user_turns, user_contents})

      json(conn, %{
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}
        ]
      })
    end

    match _ do
      json(conn, %{"ok" => true, "result" => true})
    end

    defp test_pid, do: read(:tg_sender_tag_test_pid, self())
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
    home = Path.join(System.tmp_dir!(), "pepe_tg_sendertag_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.Test.LedgerDrain.drain!()
    Pepe.RepoSetup.start!()

    test_pid = self()
    {:ok, _} = Elixir.Agent.start_link(fn -> [] end, name: :tg_sender_tag_updates)
    {:ok, _} = Elixir.Agent.start_link(fn -> test_pid end, name: :tg_sender_tag_test_pid)

    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"

    prev_base = Application.get_env(:pepe, :telegram_api_base)
    Application.put_env(:pepe, :telegram_api_base, base)

    prev_otel_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
    System.delete_env("OTEL_EXPORTER_OTLP_ENDPOINT")

    Config.put_model(%Model{name: "mock", base_url: base, api_key: "k", model: "m"})
    Config.put_agent(%AgentCfg{name: "assistant", model: "mock", system_prompt: "hi", tools: [], max_iterations: 2})

    on_exit(fn ->
      if prev_base,
        do: Application.put_env(:pepe, :telegram_api_base, prev_base),
        else: Application.delete_env(:pepe, :telegram_api_base)

      if prev_otel_endpoint,
        do: System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", prev_otel_endpoint),
        else: System.delete_env("OTEL_EXPORTER_OTLP_ENDPOINT")

      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    %{chat: -2_000_000 - System.unique_integer([:positive])}
  end

  defp start_bot! do
    bot = %{"name" => "default", "bot_token" => "t", "agent" => "assistant", "require_mention" => false}
    Config.put_telegram(bot)
    start_supervised!(%{id: Telegram, start: {Telegram, :start_link, [bot]}})
    :ok
  end

  defp queue_text(chat, text, opts) do
    update = %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "chat" => %{"id" => chat, "type" => opts[:chat_type] || "private"},
        "from" => opts[:from] || %{"id" => 1},
        "text" => text
      }
    }

    Elixir.Agent.update(:tg_sender_tag_updates, &(&1 ++ [update]))
  end

  test "a group message is tagged with the sender's name", %{chat: chat} do
    start_bot!()
    queue_text(chat, "preciso do guia", chat_type: "supergroup", from: %{"id" => 42, "first_name" => "Salvador"})

    assert_receive {:model_saw, content}, 5_000
    assert content == "pepe_sender_name: Salvador\npreciso do guia"
  end

  test "a private chat message is never tagged", %{chat: chat} do
    start_bot!()
    queue_text(chat, "preciso do guia", chat_type: "private", from: %{"id" => 42, "first_name" => "Salvador"})

    assert_receive {:model_saw, content}, 5_000
    assert content == "preciso do guia"
  end

  test "a group sender with no name falls back to their @username", %{chat: chat} do
    start_bot!()
    queue_text(chat, "oi", chat_type: "group", from: %{"id" => 7, "username" => "svd"})

    assert_receive {:model_saw, content}, 5_000
    assert content == "pepe_sender_name: svd\noi"
  end

  test "only the newest message in a request carries a sender label; earlier ones are stripped",
       %{chat: chat} do
    start_bot!()

    queue_text(chat, "primeira mensagem", chat_type: "supergroup", from: %{"id" => 42, "first_name" => "Salvador"})
    assert_receive {:model_saw, first}, 5_000
    assert first == "pepe_sender_name: Salvador\nprimeira mensagem"

    queue_text(chat, "segunda mensagem", chat_type: "supergroup", from: %{"id" => 99, "first_name" => "Jhonathas"})
    assert_receive {:model_saw_all_user_turns, [first_seen_again, second]}, 5_000

    # The current (second) turn is labeled; the first turn's label is gone from the
    # history the model sees on this call, even though it's the exact same stored
    # text that went out tagged on the previous call.
    assert first_seen_again == "primeira mensagem"
    assert second == "pepe_sender_name: Jhonathas\nsegunda mensagem"
  end

  test "the sender's display name reaches the exported trace as user.id, tagged in text or not", %{chat: chat} do
    {:ok, otel_server} = Bandit.start_link(plug: Pepe.Test.MockOtelCollector, port: 0, scheme: :http)
    {:ok, {_addr, otel_port}} = ThousandIsland.listener_info(otel_server)
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:#{otel_port}")
    Pepe.Test.MockOtelCollector.listen()

    start_bot!()

    # A private chat never tags the text itself (see the test above), but the trace's
    # user.id should still carry the sender's name now, not just the chat-level session id.
    queue_text(chat, "preciso do guia", chat_type: "private", from: %{"id" => 42, "first_name" => "Salvador"})
    assert_receive {:otel_request, _headers, body}, 5_000

    [%{"scopeSpans" => [%{"spans" => spans}]}] = body["resourceSpans"]
    root = Enum.find(spans, &(&1["name"] == "pepe.run"))

    user_id =
      Enum.find_value(root["attributes"], fn
        %{"key" => "user.id", "value" => %{"stringValue" => v}} -> v
        _ -> nil
      end)

    assert user_id == "Salvador"
  end
end

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
      [%{"content" => content} | _] =
        conn.body_params["messages"] |> Enum.reverse() |> Enum.filter(&(&1["role"] == "user"))

      send(test_pid(), {:model_saw, content})

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

    Config.put_model(%Model{name: "mock", base_url: base, api_key: "k", model: "m"})
    Config.put_agent(%AgentCfg{name: "assistant", model: "mock", system_prompt: "hi", tools: [], max_iterations: 2})

    on_exit(fn ->
      if prev_base,
        do: Application.put_env(:pepe, :telegram_api_base, prev_base),
        else: Application.delete_env(:pepe, :telegram_api_base)

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
    assert content == "Salvador: preciso do guia"
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
    assert content == "svd: oi"
  end
end

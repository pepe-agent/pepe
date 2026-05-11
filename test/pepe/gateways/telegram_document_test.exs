defmodule Pepe.Gateways.TelegramDocumentTest do
  @moduledoc """
  A document sent in a chat, end to end.

  The point of doing this at the door rather than leaving it to the agent is not that the
  agent cannot do it. It can, and until now it had to: identify the file, choose a library,
  install it, write a script, run it. That costs several turns, it needs the agent to hold
  `bash`, which a client-facing agent must never hold, and it comes out differently every
  time. Here the text exists before routing does, so the model is handed a message.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent, as: AgentCfg
  alias Pepe.Config.Model
  alias Pepe.Gateways.Telegram

  @user 77

  # Plays Telegram (getUpdates / getFile / the download / sendMessage) and the model, which
  # answers by handing back the prompt it was given, so a test can see what actually reached it.
  defmodule MockPlug do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:dispatch)

    get "/bot:token/getUpdates" do
      updates = Elixir.Agent.get_and_update(:tg_doc_updates, &{&1, []})
      json(conn, %{"ok" => true, "result" => updates})
    end

    get "/bot:token/getFile" do
      name = Elixir.Agent.get(:tg_doc_name, & &1)
      json(conn, %{"ok" => true, "result" => %{"file_path" => "documents/#{name}"}})
    end

    get "/bot:token/getMe" do
      json(conn, %{"ok" => true, "result" => %{"username" => "pepebot"}})
    end

    get "/file/bot:token/documents/*rest" do
      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream")
      |> Plug.Conn.send_resp(200, Elixir.Agent.get(:tg_doc_body, & &1))
    end

    post "/bot:token/sendMessage" do
      send(test_pid(), {:sent, conn.body_params["chat_id"], conn.body_params["text"]})
      json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
    end

    # The model. It reports the user message it was given, so the test can assert that the
    # document's text was already in it.
    post "/chat/completions" do
      said =
        conn.body_params["messages"]
        |> Enum.filter(&(&1["role"] == "user"))
        |> Enum.map_join("\n", & &1["content"])

      send(test_pid(), {:model_saw, said})

      json(conn, %{
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => "read it"}, "finish_reason" => "stop"}
        ]
      })
    end

    match _ do
      json(conn, %{"ok" => true, "result" => true})
    end

    defp test_pid, do: Elixir.Agent.get(:tg_doc_test_pid, & &1)
    defp json(conn, body), do: conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tg_doc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    test_pid = self()
    {:ok, _} = Elixir.Agent.start_link(fn -> [] end, name: :tg_doc_updates)
    {:ok, _} = Elixir.Agent.start_link(fn -> test_pid end, name: :tg_doc_test_pid)
    {:ok, _} = Elixir.Agent.start_link(fn -> "" end, name: :tg_doc_body)
    {:ok, _} = Elixir.Agent.start_link(fn -> "file.txt" end, name: :tg_doc_name)

    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"

    prev_base = Application.get_env(:pepe, :telegram_api_base)
    Application.put_env(:pepe, :telegram_api_base, base)

    Config.put_model(%Model{name: "mock", base_url: base, api_key: "k", model: "m"})

    Config.put_agent(%AgentCfg{
      name: "assistant",
      model: "mock",
      system_prompt: "hi",
      # No shell. This is the agent a client talks to, and it is exactly the one that could
      # not read a document at all before.
      tools: [],
      max_iterations: 3
    })

    on_exit(fn ->
      if prev_base,
        do: Application.put_env(:pepe, :telegram_api_base, prev_base),
        else: Application.delete_env(:pepe, :telegram_api_base)

      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    # A chat of its own. The session is keyed on the chat id, so a shared one would let each
    # test read the documents of the one before it, and the model mock would happily report
    # them as this test's.
    %{chat: 4_000_000 + System.unique_integer([:positive])}
  end

  defp start_bot! do
    bot = %{"name" => "default", "bot_token" => "t", "agent" => "assistant"}
    Config.put_telegram(bot)
    start_supervised!(%{id: Telegram, start: {Telegram, :start_link, [bot]}})
    :ok
  end

  defp send_document(chat, name, body, opts \\ []) do
    Elixir.Agent.update(:tg_doc_name, fn _ -> name end)
    Elixir.Agent.update(:tg_doc_body, fn _ -> body end)

    update = %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "chat" => %{"id" => chat, "type" => opts[:chat_type] || "private"},
        "from" => %{"id" => @user},
        "caption" => opts[:caption] || "",
        "document" => %{"file_id" => "f1", "file_name" => name}
      }
    }

    Elixir.Agent.update(:tg_doc_updates, &(&1 ++ [update]))
  end

  test "the text of the document reaches the model, in the same message", %{chat: chat} do
    start_bot!()

    send_document(chat, "prices.txt", "The annual plan costs 990 euros.", caption: "how much is the annual plan?")

    assert_receive {:model_saw, said}, 5_000

    # The instruction and the material arrive as one thing. The agent answers about the
    # content instead of first having to go and find it.
    assert said =~ "how much is the annual plan?"
    assert said =~ "The annual plan costs 990 euros."
    assert said =~ "prices.txt"

    assert_receive {:sent, ^chat, "read it"}, 5_000
  end

  test "it works for an agent with no shell, which is the whole point", %{chat: chat} do
    start_bot!()

    # This agent has no tools at all. Before, a document sent to it was unreadable: the
    # fallback is "the agent works it out", and this one has nothing to work it out with.
    assert Config.get_agent("assistant").tools == []

    send_document(chat, "note.md", "# Deploy\n\nRun it on Friday.", caption: "when?")

    assert_receive {:model_saw, said}, 5_000
    assert said =~ "Run it on Friday."
  end

  test "the agent is told where the file is, because it only got part of a long one", %{chat: chat} do
    start_bot!()

    send_document(chat, "book.txt", String.duplicate("word ", 20_000), caption: "summarise")

    assert_receive {:model_saw, said}, 5_000

    # Handed over in part, so one attachment cannot eat the context window, and told where the
    # rest is so it can go and read it if it has to.
    assert said =~ "media/"
    assert said =~ "read it there if you need more"
  end

  test "a file we cannot read still falls through to the agent", %{chat: chat} do
    start_bot!()

    # A .zip is a box, not a document. Nothing is opened at the door; the agent gets the file
    # and decides, at the permission gate, what to do with it.
    send_document(chat, "stuff.zip", "PK\x03\x04 not really", caption: "what is in here?")

    assert_receive {:model_saw, said}, 5_000

    refute said =~ "--- Attached file"
    assert said =~ "media/"
  end
end

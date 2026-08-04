defmodule Pepe.Gateways.TelegramPermissionTimeoutTest do
  @moduledoc """
  A Telegram permission prompt nobody answers must not read to the model as an explicit
  refusal - the agent should be free to try a different approach instead of concluding "the
  user said no" from silence. See `Pepe.Tools.AskUser`'s `:timeout` handling for the sibling
  prompt (`ask_user`) that already made this distinction; the permission gate didn't.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent, as: AgentCfg
  alias Pepe.Config.Model
  alias Pepe.Gateways.Telegram

  @user 88

  # Plays Telegram (getUpdates / sendMessage) and the model: the first completion asks for a
  # `bash` call (which will need permission and never gets one), the second - reached once the
  # denial's tool result comes back - answers plainly so the test can see what the model saw.
  defmodule MockPlug do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:dispatch)

    get "/bot:token/getUpdates" do
      json(conn, %{"ok" => true, "result" => take(:tg_pt_updates, [])})
    end

    get "/bot:token/getMe" do
      json(conn, %{"ok" => true, "result" => %{"username" => "pepebot"}})
    end

    post "/bot:token/sendMessage" do
      send(test_pid(), {:sent, conn.body_params["chat_id"], conn.body_params["text"]})
      json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
    end

    post "/chat/completions" do
      msgs = conn.body_params["messages"]

      message =
        if Enum.any?(msgs, &(&1["role"] == "tool")) do
          tool_text = msgs |> Enum.filter(&(&1["role"] == "tool")) |> Enum.map_join("\n", & &1["content"])
          send(test_pid(), {:model_saw_tool_result, tool_text})
          %{"role" => "assistant", "content" => "noted"}
        else
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              # `rm -rf` trips the `:deletes` risk hint, so this actually reaches the permission
              # gate instead of taking bash/run_script's free pass for an unclassified command
              # with a human on the line (Pepe.Permissions' `@ask_free_when_interactive`).
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{"name" => "bash", "arguments" => Jason.encode!(%{"command" => "rm -rf /tmp/pepe_test_dummy"})}
              }
            ]
          }
        end

      json(conn, %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]})
    end

    match _ do
      json(conn, %{"ok" => true, "result" => true})
    end

    defp test_pid, do: read(:tg_pt_test_pid, self())
    defp read(name, default), do: safe(fn -> Elixir.Agent.get(name, & &1) end, default)
    defp take(name, default), do: safe(fn -> Elixir.Agent.get_and_update(name, &{&1, []}) end, default)

    defp safe(fun, default) do
      fun.()
    catch
      :exit, _ -> default
    end

    defp json(conn, body), do: conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tg_pt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.Test.LedgerDrain.drain!()
    Pepe.RepoSetup.start!()

    test_pid = self()
    {:ok, _} = Elixir.Agent.start_link(fn -> [] end, name: :tg_pt_updates)
    {:ok, _} = Elixir.Agent.start_link(fn -> test_pid end, name: :tg_pt_test_pid)

    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"

    prev_base = Application.get_env(:pepe, :telegram_api_base)
    Application.put_env(:pepe, :telegram_api_base, base)

    # Shrink the wait to nothing - the point of this test is the `after` branch, not a real
    # 5-minute wait.
    prev_timeout = Application.get_env(:pepe, :telegram_perm_timeout_ms)
    Application.put_env(:pepe, :telegram_perm_timeout_ms, 50)

    Config.put_model(%Model{name: "mock", base_url: base, api_key: "k", model: "m"})

    Config.put_agent(%AgentCfg{
      name: "assistant",
      model: "mock",
      system_prompt: "hi",
      tools: ["bash"],
      # No auto_approve: bash needs a permission prompt, and nobody is going to answer it.
      auto_approve: [],
      max_iterations: 3
    })

    on_exit(fn ->
      if prev_base, do: Application.put_env(:pepe, :telegram_api_base, prev_base), else: Application.delete_env(:pepe, :telegram_api_base)

      if prev_timeout,
        do: Application.put_env(:pepe, :telegram_perm_timeout_ms, prev_timeout),
        else: Application.delete_env(:pepe, :telegram_perm_timeout_ms)

      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    %{chat: 5_000_000 + System.unique_integer([:positive])}
  end

  defp start_bot! do
    bot = %{"name" => "default", "bot_token" => "t", "agent" => "assistant"}
    Config.put_telegram(bot)
    start_supervised!(%{id: Telegram, start: {Telegram, :start_link, [bot]}})
    :ok
  end

  defp send_text(chat, text) do
    update = %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "chat" => %{"id" => chat, "type" => "private"},
        "from" => %{"id" => @user},
        "text" => text
      }
    }

    Elixir.Agent.update(:tg_pt_updates, &(&1 ++ [update]))
  end

  test "a permission prompt nobody answers reads as a timeout, not a refusal", %{chat: chat} do
    start_bot!()

    send_text(chat, "clean up the temp dir")

    assert_receive {:model_saw_tool_result, tool_text}, 5_000

    assert tool_text =~ "nobody answered in time"
    refute tool_text =~ "the user did not authorize running `bash`. Do not retry"

    assert_receive {:sent, ^chat, "noted"}, 5_000
  end
end

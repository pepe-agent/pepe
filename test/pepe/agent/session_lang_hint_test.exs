defmodule Pepe.Agent.SessionLangHintTest do
  @moduledoc """
  A `lang` chat opt (the widget's `data-lang`, threaded from the WebSocket join
  payload) injects a `<system-reminder>` user turn nudging the reply language - only
  on a session's first-ever turn, so a later turn's own language isn't fought. (A user
  turn, not a system message: the Anthropic/Responses adapters drop all but the first
  system message, which silently killed the hint on those providers.)
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # Echoes every request's message contents back to the test process, then answers
  # plainly - lets a test assert on exactly what the model was sent (the lang hint is a
  # user turn now, so we can't filter to just system messages).
  defmodule EchoPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)
      contents = req["messages"] |> Enum.map(& &1["content"])
      send(:pepe_lang_hint_test, {:seen_messages, contents})

      payload = %{
        "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    Process.register(self(), :pepe_lang_hint_test)

    home = Path.join(System.tmp_dir!(), "pepe_lang_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, server} = Bandit.start_link(plug: EchoPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"})
    Config.put_agent(%Agent{name: "greeter", model: "mock", tools: [], max_iterations: 5})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    key = "test:lang:#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, "greeter")
    %{key: key}
  end

  test "the first turn's lang opt is sent as a message mentioning the language", %{key: key} do
    assert {:ok, _reply} = Session.chat(key, "oi", lang: "pt-BR")
    assert_receive {:seen_messages, messages}, 2_000
    assert Enum.any?(messages, &(&1 =~ "pt-BR"))
  end

  test "a later turn does not inject the hint a second time", %{key: key} do
    assert {:ok, _reply} = Session.chat(key, "oi", lang: "pt-BR")
    assert_receive {:seen_messages, first}, 2_000
    assert Enum.count(first, &(&1 =~ "pt-BR")) == 1

    # The hint from turn 1 persists in history like any other message (it's not
    # stripped out afterwards) - what matters is it's not injected a SECOND time.
    assert {:ok, _reply} = Session.chat(key, "de novo", lang: "pt-BR")
    assert_receive {:seen_messages, second}, 2_000
    assert Enum.count(second, &(&1 =~ "pt-BR")) == 1
  end

  test "no lang opt means no hint at all", %{key: key} do
    assert {:ok, _reply} = Session.chat(key, "hi")
    assert_receive {:seen_messages, messages}, 2_000
    refute Enum.any?(messages, &(&1 =~ "declares its language"))
  end
end

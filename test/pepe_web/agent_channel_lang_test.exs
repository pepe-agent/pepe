defmodule PepeWeb.AgentChannelLangTest do
  @moduledoc """
  A `lang` passed in the channel's join payload (the widget's `data-lang`) reaches
  the model as a `<system-reminder>` hint on the first turn - see
  `Pepe.Agent.Session`'s `maybe_add_lang_hint/3`.
  """
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  defmodule EchoPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)
      contents = req["messages"] |> Enum.map(& &1["content"])
      send(:pepe_acl_test, {:seen_messages, contents})

      chunks = [
        "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "ok"}, "finish_reason" => nil}]})}\n\n",
        "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]})}\n\n",
        "data: [DONE]\n\n"
      ]

      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
      Enum.each(chunks, fn c -> {:ok, _} = chunk(conn, c) end)
      conn
    end
  end

  setup do
    Process.register(self(), :pepe_acl_test)

    {:ok, _} = Application.ensure_all_started(:pepe)
    {:ok, server} = Bandit.start_link(plug: EchoPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    home = Path.join(System.tmp_dir!(), "pepe_acl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Config.Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    Config.put_agent(%Config.Agent{name: "greeter", model: "mock", tools: [], max_iterations: 5})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "a lang in the join payload is sent as a hint on the first turn" do
    {:ok, socket} = connect(PepeWeb.AgentSocket, %{}, connect_info: %{peer_data: %{address: {127, 0, 0, 1}}})
    {:ok, _reply, socket} = subscribe_and_join(socket, "agent:greeter", %{"session" => "al1", "lang" => "es-ES"})

    push(socket, "prompt", %{"text" => "hola"})

    assert_push "done", %{}, 2_000
    assert_receive {:seen_messages, messages}, 2_000
    assert Enum.any?(messages, &(&1 =~ "es-ES"))
  end

  test "no lang in the join payload means no hint" do
    {:ok, socket} = connect(PepeWeb.AgentSocket, %{}, connect_info: %{peer_data: %{address: {127, 0, 0, 1}}})
    {:ok, _reply, socket} = subscribe_and_join(socket, "agent:greeter", %{"session" => "al2"})

    push(socket, "prompt", %{"text" => "hi"})

    assert_push "done", %{}, 2_000
    assert_receive {:seen_messages, messages}, 2_000
    refute Enum.any?(messages, &(&1 =~ "declares its language"))
  end
end

defmodule PepeWeb.OpenAIControllerTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    home = Path.join(System.tmp_dir!(), "pepe_ctrl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    config = %{
      "default_model" => "mock",
      "default_agent" => "assistant",
      "models" => %{
        "mock" => %{
          "base_url" => "http://localhost:#{port}",
          "api_key" => "x",
          "model" => "mock-model"
        }
      },
      "agents" => %{
        "assistant" => %{"model" => "mock", "system_prompt" => "You are helpful.", "tools" => []}
      }
    }

    File.write!(Path.join(home, "config.json"), Jason.encode!(config))

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "GET /v1/models lists agents and models" do
    conn = get(build_conn(), "/v1/models")
    body = json_response(conn, 200)
    ids = Enum.map(body["data"], & &1["id"])
    assert "assistant" in ids
    assert "mock" in ids
  end

  test "POST /v1/chat/completions returns an OpenAI-shaped completion" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/chat/completions", %{
        "model" => "assistant",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    body = json_response(conn, 200)
    assert body["object"] == "chat.completion"
    assert hd(body["choices"])["message"]["content"] == "Hello from the mock!"
  end

  test "GET /health reports ok" do
    conn = get(build_conn(), "/health")
    assert json_response(conn, 200)["status"] == "ok"
  end

  test "session_id keeps the conversation server-side across calls" do
    sid = "sess-#{System.unique_integer([:positive])}"

    post_msg = fn text ->
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/chat/completions", %{
        "model" => "assistant",
        "session_id" => sid,
        "messages" => [%{"role" => "user", "content" => text}]
      })
    end

    body1 = json_response(post_msg.("oi"), 200)
    assert body1["session_id"] == sid
    assert hd(body1["choices"])["message"]["content"] == "Hello from the mock!"

    _body2 = json_response(post_msg.("e agora?"), 200)

    # system + (user + assistant) * 2 = 5 messages retained server-side.
    # The key is scoped by the agent's scope ("root" here) to isolate tenants.
    history = Pepe.Agent.Session.history("api:root:" <> sid)
    roles = Enum.map(history, & &1["role"])
    assert roles == ["system", "user", "assistant", "user", "assistant"]
  end

  test "the standard OpenAI `user` field keys the session (preferred over session_id)" do
    uid = "u-#{System.unique_integer([:positive])}"

    post_msg = fn text ->
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/chat/completions", %{
        "model" => "assistant",
        "user" => uid,
        "messages" => [%{"role" => "user", "content" => text}]
      })
    end

    json_response(post_msg.("oi"), 200)
    json_response(post_msg.("e agora?"), 200)

    history = Pepe.Agent.Session.history("api:root:" <> uid)
    roles = Enum.map(history, & &1["role"])
    assert roles == ["system", "user", "assistant", "user", "assistant"]
  end

  test "user + session_id combine into a `user:session_id` key (independent threads per user)" do
    uid = "u-#{System.unique_integer([:positive])}"

    post_msg = fn sid, text ->
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/chat/completions", %{
        "model" => "assistant",
        "user" => uid,
        "session_id" => sid,
        "messages" => [%{"role" => "user", "content" => text}]
      })
    end

    json_response(post_msg.("t1", "oi thread 1"), 200)
    json_response(post_msg.("t2", "oi thread 2"), 200)

    # The two threads of the same user are kept apart under composite keys.
    assert Pepe.Agent.Session.history("api:root:#{uid}:t1") |> Enum.count(&(&1["role"] == "user")) == 1
    assert Pepe.Agent.Session.history("api:root:#{uid}:t2") |> Enum.count(&(&1["role"] == "user")) == 1
  end
end

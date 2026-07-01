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
    assert "default/assistant" in ids
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
    # The key is scoped by the agent's scope ("default" here) to isolate tenants.
    history = Pepe.Agent.Session.history(akey(sid))
    roles = Enum.map(history, & &1["role"])
    assert roles == ["system", "user", "assistant", "user", "assistant"]
  end

  test "the standard OpenAI `user` field keys the session when no session_id is sent" do
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

    # One session, keyed on the conversation id (the `user`) plus the agent, both turns accumulated.
    roles = Pepe.Agent.Session.history(akey(uid)) |> Enum.map(& &1["role"])
    assert roles == ["system", "user", "assistant", "user", "assistant"]
  end

  test "the X-Session-Id header keys the session when no session_id param is sent" do
    sid = "hdr-#{System.unique_integer([:positive])}"

    post_msg = fn text ->
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-session-id", sid)
      |> post("/v1/chat/completions", %{
        "model" => "assistant",
        "messages" => [%{"role" => "user", "content" => text}]
      })
    end

    assert json_response(post_msg.("oi"), 200)["session_id"] == sid
    json_response(post_msg.("e agora?"), 200)

    roles = Pepe.Agent.Session.history(akey(sid)) |> Enum.map(& &1["role"])
    assert roles == ["system", "user", "assistant", "user", "assistant"]
  end

  test "session_id identifies the conversation - a sometimes-present `user` never forks it" do
    # The fork bug: a client that always sends session_id but `user` only sometimes would otherwise
    # alternate between keys `s` and `user:s`, splitting one conversation in two. session_id now
    # dominates, so presence or absence of `user` lands both turns in the SAME conversation.
    sid = "s-#{System.unique_integer([:positive])}"

    post_msg = fn user, text ->
      params = %{"model" => "assistant", "session_id" => sid, "messages" => [%{"role" => "user", "content" => text}]}
      params = if user, do: Map.put(params, "user", user), else: params

      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/chat/completions", params)
    end

    json_response(post_msg.(nil, "oi"), 200)
    json_response(post_msg.("alice", "e agora?"), 200)

    # One conversation for this session_id (not two), with both turns in it.
    assert api_keys_for(sid) == [akey(sid)]
    assert Pepe.Agent.Session.history(akey(sid)) |> Enum.count(&(&1["role"] == "user")) == 2
  end

  test "two different models (agents) sharing one session_id do NOT cross conversations" do
    # `Pepe.Agent.chat` binds an agent only at session creation; without an agent dimension in the
    # key, the second model's request would be answered by the first agent, with its history.
    Pepe.Config.put_agent(%Pepe.Config.Agent{name: "other", model: "mock", system_prompt: "Other.", tools: []})
    sid = "x-#{System.unique_integer([:positive])}"

    post_msg = fn model, text ->
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/chat/completions", %{
        "model" => model,
        "session_id" => sid,
        "messages" => [%{"role" => "user", "content" => text}]
      })
    end

    json_response(post_msg.("assistant", "hi assistant"), 200)
    json_response(post_msg.("other", "hi other"), 200)

    # Each agent keeps its own thread under the same session_id: two sessions for this id.
    assert [_, _] = api_keys_for(sid)
  end

  test "with neither `user` nor `session_id` the call is stateless: no session is kept" do
    before = api_session_keys()

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/chat/completions", %{
        "model" => "assistant",
        "messages" => [%{"role" => "user", "content" => "oi"}]
      })

    body = json_response(conn, 200)
    assert hd(body["choices"])["message"]["content"] == "Hello from the mock!"

    # Nothing to correlate the call with, so nothing is retained server-side.
    refute Map.has_key?(body, "session_id")
    assert api_session_keys() == before
  end

  defp api_session_keys do
    Pepe.Agent.SessionSupervisor.list()
    |> Enum.filter(&String.starts_with?(&1, "api:"))
    |> Enum.sort()
  end

  # The session key for the default `assistant` agent (canonical handle "default/assistant") and a
  # given conversation id. Tests share the Registry, so match by the exact key rather than listing.
  defp akey(id), do: "api:default:default/assistant:" <> id

  # Every api session whose conversation id is `id` (any agent) - for the fork/cross tests.
  defp api_keys_for(id), do: Enum.filter(api_session_keys(), &String.ends_with?(&1, ":" <> id))

  test "different session_ids are independent conversations for the same user" do
    uid = "u-#{System.unique_integer([:positive])}"
    n = System.unique_integer([:positive])
    sid1 = "ta-#{n}"
    sid2 = "tb-#{n}"

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

    json_response(post_msg.(sid1, "oi thread 1"), 200)
    json_response(post_msg.(sid2, "oi thread 2"), 200)

    # Two distinct session_ids -> two independent conversations, each with its single turn.
    assert api_keys_for(sid1) == [akey(sid1)]
    assert api_keys_for(sid2) == [akey(sid2)]
    assert Pepe.Agent.Session.history(akey(sid1)) |> Enum.count(&(&1["role"] == "user")) == 1
    assert Pepe.Agent.Session.history(akey(sid2)) |> Enum.count(&(&1["role"] == "user")) == 1
  end
end

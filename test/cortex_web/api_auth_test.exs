defmodule CortexWeb.ApiAuthTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  alias Cortex.ApiToken

  @endpoint CortexWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:cortex)
    {:ok, server} = Bandit.start_link(plug: Cortex.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    home = Path.join(System.tmp_dir!(), "cortex_auth_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)

    model = %{"base_url" => "http://localhost:#{port}", "api_key" => "x", "model" => "mock-model"}
    agent = fn -> %{"model" => "mock", "system_prompt" => "hi", "tools" => []} end

    config = %{
      "default_model" => "mock",
      "default_agent" => "assistant",
      "models" => %{"mock" => model},
      "companies" => %{"acme" => %{}, "globex" => %{}},
      "agents" => %{
        "assistant" => agent.(),
        "acme/vendas" => agent.(),
        "globex/vendas" => agent.()
      },
      "api_tokens" => %{
        "troot" => %{"hash" => ApiToken.hash("ctx_root"), "company" => nil, "agent" => nil},
        "tacme" => %{"hash" => ApiToken.hash("ctx_acme"), "company" => "acme", "agent" => nil},
        "tagent" => %{
          "hash" => ApiToken.hash("ctx_agent"),
          "company" => "acme",
          "agent" => "acme/vendas"
        }
      }
    }

    File.write!(Path.join(home, "config.json"), Jason.encode!(config))

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp post_chat(token, model) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> then(fn c ->
      if token, do: put_req_header(c, "authorization", "Bearer #{token}"), else: c
    end)
    |> post("/v1/chat/completions", %{
      "model" => model,
      "messages" => [%{"role" => "user", "content" => "hi"}]
    })
  end

  test "with tokens configured, a call with no token is rejected" do
    assert post_chat(nil, "assistant").status == 401
  end

  test "an unknown token is rejected" do
    assert post_chat("ctx_nope", "assistant").status == 401
  end

  test "the Azure-style api-key header is accepted as a fallback" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("api-key", "ctx_acme")
      |> post("/v1/chat/completions", %{
        "model" => "vendas",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert conn.status == 200
  end

  test "a company token reaches its own agent but not another company's" do
    assert post_chat("ctx_acme", "acme/vendas").status == 200
    # bare name qualifies into the token's company
    assert post_chat("ctx_acme", "vendas").status == 200
    # another company's agent is forbidden
    assert post_chat("ctx_acme", "globex/vendas").status == 403
    # a root agent is out of scope for a company token
    assert post_chat("ctx_acme", "assistant").status == 403
  end

  test "an agent-scoped token is locked to its agent regardless of the model field" do
    assert post_chat("ctx_agent", "acme/vendas").status == 200
    # even asking for a peer stays on the locked agent (ignored), so it still works
    assert post_chat("ctx_agent", "globex/vendas").status == 200
  end

  test "a root token reaches root agents but not company agents" do
    assert post_chat("ctx_root", "assistant").status == 200
    assert post_chat("ctx_root", "acme/vendas").status == 403
  end

  test "GET /v1/models is filtered to the token's scope" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer ctx_acme")
      |> get("/v1/models")

    ids = json_response(conn, 200)["data"] |> Enum.map(& &1["id"])
    assert "acme/vendas" in ids
    refute "globex/vendas" in ids
    refute "assistant" in ids
    # company tokens don't see raw model connections
    refute "mock" in ids
  end
end

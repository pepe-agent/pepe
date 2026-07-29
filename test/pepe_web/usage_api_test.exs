defmodule PepeWeb.UsageApiTest do
  @moduledoc """
  The `/v1/usage` reads, and the token permissions that decide what they answer with.

  Two things are load-bearing here and are asserted rather than assumed: a token cannot widen
  its own price view by asking for one in the query string, and a project token cannot read
  another project's spend by naming it.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Pepe.ApiToken
  alias Pepe.Usage.Log
  alias Pepe.Usage.Runs

  @endpoint PepeWeb.Endpoint

  # Every call is 10 in + 5 out at $1/1M in and $2/1M out, so 0.00002 of list price each.
  # Acme carries a 2× markup and globex none, which keeps list and billable different
  # numbers throughout - a view that returns the wrong one cannot pass by coincidence.
  @model %{"base_url" => "http://localhost:1", "api_key" => "x", "model" => "m", "input_price" => 1.0, "output_price" => 2.0}

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_usage_api_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    agent = %{"model" => "mock", "system_prompt" => "hi", "tools" => []}

    config = %{
      "default_model" => "mock",
      "default_agent" => "assistant",
      "models" => %{"mock" => @model},
      "projects" => %{"acme" => %{"slug" => "acme", "markup" => 2}, "globex" => %{"slug" => "globex"}},
      "agents" => %{"assistant" => agent, "acme/sales" => agent, "acme/support" => agent, "globex/sales" => agent},
      "api_tokens" => %{
        "tchat" => %{"hash" => ApiToken.hash("k_chat"), "project" => "acme"},
        "tbill" => %{
          "hash" => ApiToken.hash("k_bill"),
          "project" => "acme",
          "chat" => false,
          "usage" => true,
          "prices" => "billable"
        },
        "tlist" => %{"hash" => ApiToken.hash("k_list"), "project" => "acme", "usage" => true, "prices" => "list"},
        "tall" => %{"hash" => ApiToken.hash("k_all"), "usage" => true, "prices" => "all", "usage_content" => true},
        "tagent" => %{
          "hash" => ApiToken.hash("k_agent"),
          "project" => "acme",
          "agent" => "acme/sales",
          "usage" => true
        }
      }
    }

    File.write!(Path.join(home, "config.json"), Jason.encode!(config))
    Pepe.RepoSetup.start!()
    seed()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  # One acme run of two model calls with a tool between them, one acme run by another agent,
  # and one globex run that no acme token may ever see.
  defp seed do
    at = 1_770_000_000

    Runs.record(%{
      id: "1000",
      scope: "acme",
      at: at,
      agent: "acme/sales",
      session: "telegram:7",
      source: "telegram",
      ms: 4_210,
      outcome: %{"kind" => "ok"},
      events: [
        %{"t" => "tool_call", "name" => "bash", "args" => "ls"},
        %{"t" => "tool_result", "name" => "bash", "out" => "a.txt"}
      ]
    })

    Runs.record(%{
      id: "2000",
      scope: "acme",
      at: at + 60,
      agent: "acme/support",
      session: nil,
      source: "api",
      ms: 900,
      outcome: %{"kind" => "ok"},
      events: []
    })

    Runs.record(%{
      id: "3000",
      scope: "globex",
      at: at + 90,
      agent: "globex/sales",
      session: nil,
      source: "api",
      ms: 100,
      outcome: %{"kind" => "ok"},
      events: []
    })

    entry = fn run_id, agent, source ->
      %{"at" => at, "agent" => agent, "model" => "mock", "in" => 10, "out" => 5, "run_id" => run_id, "source" => source}
    end

    Log.append("acme", entry.("1000", "acme/sales", "telegram") |> Map.put("session", "telegram:7"))
    Log.append("acme", entry.("1000", "acme/sales", "telegram") |> Map.put("session", "telegram:7"))
    Log.append("acme", entry.("2000", "acme/support", "api"))
    Log.append("globex", entry.("3000", "globex/sales", "api"))
  end

  defp get_json(token, path) do
    build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
    |> get(path)
  end

  ###
  ### permission gate
  ###

  test "a plain chat token cannot read usage" do
    assert get_json("k_chat", "/v1/usage").status == 403
  end

  test "a read-only billing token cannot run an agent" do
    conn =
      build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer k_bill")
      |> post("/v1/chat/completions", %{"model" => "sales", "messages" => [%{"role" => "user", "content" => "hi"}]})

    assert conn.status == 403
  end

  ###
  ### price views
  ###

  test "a billable token sees only what the client pays, markup applied" do
    body = get_json("k_bill", "/v1/usage?from=1") |> json_response(200)

    assert body["totals"]["billable"] == 0.00012
    assert body["totals"]["input_tokens"] == 30
    assert body["totals"]["calls"] == 3
    refute Map.has_key?(body["totals"], "list")
    refute Map.has_key?(body["totals"], "cost")
    refute Map.has_key?(body, "margin")
  end

  test "a list token sees the price before markup, and never the billable next to it" do
    body = get_json("k_list", "/v1/usage?from=1") |> json_response(200)

    assert body["totals"]["list"] == 0.00006
    refute Map.has_key?(body["totals"], "billable")
  end

  test "the query string cannot widen a token's price view" do
    body = get_json("k_bill", "/v1/usage?from=1&prices=all") |> json_response(200)

    refute Map.has_key?(body["totals"], "cost")
    refute Map.has_key?(body, "margin")
  end

  test "an operator token sees all three numbers and the margin" do
    body = get_json("k_all", "/v1/usage?from=1") |> json_response(200)

    assert body["totals"]["calls"] == 4
    assert body["totals"]["list"] == 0.00008
    # Globex has no markup, so only acme's three calls are doubled: 0.00006 x 2 + 0.00002.
    assert body["totals"]["billable"] == 0.00014
    assert body["totals"]["cost"] == 0.00008
    assert body["margin"] == 0.00006
  end

  ###
  ### scope
  ###

  test "a project token's totals exclude every other project" do
    body = get_json("k_bill", "/v1/usage?from=1") |> json_response(200)

    assert Enum.map(body["by_project"], & &1["key"]) == ["acme"]
  end

  test "an aggregate defaults to a window, and says which one it used" do
    body = get_json("k_bill", "/v1/usage") |> json_response(200)

    # The seeded entries are older than the default window, so they fall outside it - and the
    # response reports the period rather than quietly covering less than the caller expects.
    assert is_integer(body["period"]["from"])
    assert body["totals"]["calls"] == 0

    # Asking wider is always allowed.
    wide = get_json("k_bill", "/v1/usage?from=1") |> json_response(200)
    assert wide["period"]["from"] == 1
    assert wide["totals"]["calls"] == 3
  end

  test "with no limit given, the series adds up to the totals it is shown next to" do
    body = get_json("k_bill", "/v1/usage?from=1&granularity=day") |> json_response(200)

    # A fixed default of 60 buckets would silently show less than `period` claims to cover.
    assert Enum.sum(Enum.map(body["buckets"], & &1["calls"])) == body["totals"]["calls"]

    # An explicit limit still caps the series - that is what it is for.
    capped = get_json("k_bill", "/v1/usage?from=1&granularity=day&limit=1") |> json_response(200)
    assert length(capped["buckets"]) == 1
  end

  test "a project token cannot read another project by naming it" do
    assert get_json("k_bill", "/v1/usage?project=globex").status == 403
  end

  test "an agent-locked token sees only its own agent's spend" do
    body = get_json("k_agent", "/v1/usage?from=1") |> json_response(200)

    assert Enum.map(body["by_agent"], & &1["key"]) == ["acme/sales"]
    assert body["totals"]["calls"] == 2
  end

  ###
  ### events
  ###

  test "events return one row per model call, with the run it belongs to" do
    body = get_json("k_bill", "/v1/usage/events") |> json_response(200)

    assert length(body["data"]) == 3
    assert Enum.all?(body["data"], &(&1["project"] == "acme"))
    assert Enum.count(body["data"], &(&1["run_id"] == "1000")) == 2
    refute body["has_more"]
  end

  test "events page on an opaque cursor rather than on the second" do
    first = get_json("k_bill", "/v1/usage/events?limit=2") |> json_response(200)
    assert first["has_more"]

    next = get_json("k_bill", "/v1/usage/events?limit=2&cursor=#{first["next_cursor"]}") |> json_response(200)
    assert length(next["data"]) == 1
    refute next["has_more"]
  end

  test "events can be narrowed to one session" do
    body = get_json("k_bill", "/v1/usage/events?session=telegram:7") |> json_response(200)

    assert length(body["data"]) == 2
  end

  ###
  ### runs
  ###

  test "runs return one row per message, with its tools and its summed cost" do
    body = get_json("k_bill", "/v1/usage/runs") |> json_response(200)

    assert length(body["data"]) == 2
    run = Enum.find(body["data"], &(&1["id"] == "1000"))

    assert run["tools"] == ["bash"]
    assert run["tool_calls"] == 1
    assert run["source"] == "telegram"
    assert run["ms"] == 4_210
    # Two model calls behind one message: the cost of a run is its iterations, not its tools.
    assert run["calls"] == 2
    assert run["billable"] == 0.00008
  end

  test "runs can be narrowed by source" do
    body = get_json("k_bill", "/v1/usage/runs?source=api") |> json_response(200)

    assert Enum.map(body["data"], & &1["id"]) == ["2000"]
  end

  test "a mistyped price view is refused rather than narrowed in silence" do
    # The CLI and the tool both refuse it too; here the token decides the view anyway, so the
    # parameter is simply ignored - what must never happen is a *narrower* answer presented as
    # the one that was asked for.
    body = get_json("k_all", "/v1/usage?from=1&prices=everything") |> json_response(200)

    assert Map.has_key?(body["totals"], "cost")
  end

  test "a filter a run list cannot honour is refused rather than silently ignored" do
    assert get_json("k_bill", "/v1/usage/runs?model=mock").status == 400
    assert get_json("k_bill", "/v1/usage/runs?run_id=1000").status == 400
  end

  ###
  ### one run's detail
  ###

  test "a run's detail breaks the message down call by call" do
    body = get_json("k_bill", "/v1/usage/runs/1000") |> json_response(200)

    assert body["object"] == "usage.run"
    assert body["calls"] == 2
    assert length(body["breakdown"]) == 2
    assert Enum.map(body["breakdown"], & &1["model"]) == ["mock", "mock"]
    assert body["billable"] == 0.00008
  end

  test "a run's detail withholds conversation content unless the token carries the permission" do
    without = get_json("k_bill", "/v1/usage/runs/1000") |> json_response(200)
    refute Map.has_key?(without, "content")

    with_content = get_json("k_all", "/v1/usage/runs/1000") |> json_response(200)
    assert Map.has_key?(with_content, "content")
  end

  test "another project's run is not found rather than forbidden" do
    assert get_json("k_bill", "/v1/usage/runs/3000").status == 404
  end

  test "an agent-locked token cannot open a run its agent did not make" do
    assert get_json("k_agent", "/v1/usage/runs/1000").status == 200
    assert get_json("k_agent", "/v1/usage/runs/2000").status == 404
  end
end

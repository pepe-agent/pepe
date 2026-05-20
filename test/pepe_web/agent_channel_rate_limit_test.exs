defmodule PepeWeb.AgentChannelRateLimitTest do
  @moduledoc """
  Only a widget-scoped connection's prompts are rate-limited (its token sits in
  public page source); every other scope keeps working under the same low limit.
  """
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias Pepe.ApiToken

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_ratelimit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    prev_limit = Application.get_env(:pepe, :widget_rate_limit)
    Application.put_env(:pepe, :widget_rate_limit, 1)

    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    config = %{
      "default_agent" => "assistant",
      "models" => %{"mock" => %{"base_url" => "http://localhost:#{port}", "api_key" => "x", "model" => "mock-model"}},
      "agents" => %{"assistant" => %{"model" => "mock", "system_prompt" => "hi", "tools" => []}},
      "api_tokens" => %{
        "twidget" => %{
          "hash" => ApiToken.hash("ctx_widget"),
          "agent" => "assistant",
          "kind" => "widget",
          "allowed_origin" => "https://example.com"
        },
        "tplain" => %{"hash" => ApiToken.hash("ctx_plain"), "agent" => "assistant"}
      }
    }

    File.write!(Path.join(home, "config.json"), Jason.encode!(config))

    on_exit(fn ->
      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      if prev_limit, do: Application.put_env(:pepe, :widget_rate_limit, prev_limit), else: Application.delete_env(:pepe, :widget_rate_limit)
      Process.exit(server, :normal)
      File.rm_rf(home)
    end)

    :ok
  end

  defp join_as(token, session) do
    # A widget connect now requires an Origin matching the token; a browser always sends it.
    Process.put(:pepe_ws_request_origin, "https://example.com")
    {:ok, socket} = connect(PepeWeb.AgentSocket, %{"token" => token})
    {:ok, _reply, socket} = subscribe_and_join(socket, "agent:assistant", %{"session" => session})
    socket
  end

  # A distinct client IP per test, stashed where the socket reads it, so the token+IP buckets
  # (which are now stable across connects) don't collide across tests.
  defp with_client_ip do
    ip = {10, 0, 0, rem(System.unique_integer([:positive]), 250) + 2}
    Process.put(:pepe_ws_client_ip, ip)
    ApiToken.hash("ctx_widget") <> ":" <> (ip |> :inet.ntoa() |> to_string())
  end

  test "a widget-scoped connection is rate-limited once its budget is spent" do
    bucket = with_client_ip()
    socket = join_as("ctx_widget", "widget-#{System.unique_integer([:positive])}")

    # Exhaust the budget of 1 directly on the connection's real key, so this assertion never races
    # the first prompt's own (async, model-call-failure) error push.
    assert :ok = PepeWeb.WidgetThrottle.check(bucket)

    push(socket, "prompt", %{"text" => "hi"})
    assert_push "error", %{reason: reason}, 2_000
    assert reason =~ "rate limited"
  end

  test "rotating the session id does NOT mint a fresh budget (the bypass is closed)" do
    # The whole point of keying by token+IP: a visitor that changes the session on every connect
    # must NOT get a new bucket, or the limit means nothing. Exhaust the budget, then connect with
    # a brand-new session - it is still refused.
    bucket = with_client_ip()
    assert :ok = PepeWeb.WidgetThrottle.check(bucket)

    socket = join_as("ctx_widget", "rotated-session-#{System.unique_integer([:positive])}")
    push(socket, "prompt", %{"text" => "hi"})
    assert_push "error", %{reason: reason}, 2_000
    assert reason =~ "rate limited"
  end

  test "a plain (non-widget) token is never rate-limited by the same low budget" do
    session = "plain-#{System.unique_integer([:positive])}"
    socket = join_as("ctx_plain", session)

    # Two prompts back-to-back, well past the widget budget of 1 - both still succeed,
    # proving a non-widget scope is never checked against the throttle at all.
    push(socket, "prompt", %{"text" => "hi"})
    assert_push "done", %{content: "Hello from the mock!"}, 2_000

    push(socket, "prompt", %{"text" => "hi again"})
    assert_push "done", %{content: "Hello from the mock!"}, 2_000
  end
end

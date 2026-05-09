defmodule Pepe.Agent.OutputCapRetryTest do
  @moduledoc """
  The provider refuses because `input + max_tokens` overflows its window, though the input
  on its own fits. The old runtime had no answer for that: the 400 is not transient, so
  failover would not touch it, and the turn simply died. These pin the recovery.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Runtime
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # Refuses any request reserving more than `limit` output tokens, in the provider's own
  # words, and records every max_tokens it was asked for.
  defmodule CappedPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      asked = body |> Jason.decode!() |> Map.get("max_tokens")
      Elixir.Agent.update(:oc_asked, &(&1 ++ [asked]))

      {limit, input} = Elixir.Agent.get(:oc_limit, & &1)

      if is_integer(asked) and asked > limit do
        message =
          "max_tokens: #{asked} > context_window: #{input + limit} - " <>
            "input_tokens: #{input} = available_tokens: #{limit}"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{"error" => %{"message" => message}}))
      else
        payload = %{
          "choices" => [
            %{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}
          ]
        }

        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
      end
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_oc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, _} = Elixir.Agent.start_link(fn -> [] end, name: :oc_asked)
    {:ok, _} = Elixir.Agent.start_link(fn -> {500, 1000} end, name: :oc_limit)
    {:ok, server} = Bandit.start_link(plug: CappedPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{port: port, cwd: home}
  end

  defp setup_model(port, opts) do
    model =
      struct(
        %Model{name: "capped", base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"},
        opts
      )

    Config.put_model(model)

    agent = %Agent{name: "worker", model: "capped", system_prompt: "hi", tools: [], max_iterations: 3}
    Config.put_agent(agent)
    agent
  end

  defp asked, do: Elixir.Agent.get(:oc_asked, & &1)

  test "a refused answer reservation is lowered and the turn succeeds", %{port: port, cwd: cwd} do
    # Asks for 4000 output tokens; the provider only has room for 500.
    agent = setup_model(port, max_tokens: 4000, context_window: 128_000)

    assert {:ok, "ok", _messages} = Runtime.converse(agent, "go", cwd: cwd)

    # Asked once at the size the provider refused, then once at a size it accepts. Without
    # this, the 400 is not transient, failover never fires, and the turn just dies.
    assert [4000, second] = asked()
    assert second <= 500
    assert second > 0
  end

  test "the retry stays under the ceiling the provider stated", %{port: port, cwd: cwd} do
    Elixir.Agent.update(:oc_limit, fn _ -> {1200, 3000} end)
    agent = setup_model(port, max_tokens: 32_000, context_window: 128_000)

    assert {:ok, "ok", _} = Runtime.converse(agent, "go", cwd: cwd)
    assert [32_000, second] = asked()

    # A margin below the stated ceiling, because providers count tokens their own way and
    # landing exactly on the line is how you get refused twice.
    assert second < 1200
  end

  test "it gives up rather than retrying forever", %{port: port, cwd: cwd} do
    # A provider that refuses everything, contradicting itself: it says a thousand tokens
    # are available and then refuses a thousand tokens. A runtime that trusts the number
    # unconditionally would ask, be refused, ask again, forever.
    Elixir.Agent.update(:oc_limit, fn _ -> {0, 1000} end)
    agent = setup_model(port, max_tokens: 4000, context_window: 128_000)

    assert {:error, _reason} = Runtime.converse(agent, "go", cwd: cwd)

    # The original ask, then the two retries we allow, and then it stops and says so.
    assert [_original, _retry, _last_retry] = asked()
  end

  test "the turn reports what happened", %{port: port, cwd: cwd} do
    agent = setup_model(port, max_tokens: 4000, context_window: 128_000)
    test_pid = self()

    on_event = fn
      {:output_cap, model, cap} -> send(test_pid, {:capped, model, cap})
      _ -> :ok
    end

    assert {:ok, "ok", _} = Runtime.converse(agent, "go", cwd: cwd, on_event: on_event)

    assert_receive {:capped, "capped", cap}
    assert cap <= 500
  end
end

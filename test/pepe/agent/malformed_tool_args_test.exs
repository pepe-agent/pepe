defmodule Pepe.Agent.MalformedToolArgsTest do
  @moduledoc """
  A malformed tool-call `arguments` field doesn't crash the turn - `Pepe.Tools.execute/2`
  already returns it as an ordinary error tool-result the model can retry from. What was
  missing was a bound: a model varying its broken JSON slightly on every attempt (rather than
  repeating the identical call) never tripped `Pepe.Agent.LoopGuard`'s repetition detector,
  so it could burn the whole `max_iterations` budget instead of being cut off after a few
  consecutive failures like a genuine repeated call already is.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Runtime
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # Sends malformed JSON as a tool call's arguments for the first few turns (varying the
  # garbage each time, as a model "fixing" what it thinks was wrong would), then a plain
  # final answer once the caller stops asking for more.
  defmodule MockPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      msgs = body |> Jason.decode!() |> Map.fetch!("messages")
      tool_count = Enum.count(msgs, &(&1["role"] == "tool"))
      Elixir.Agent.update(:mta_turns, &(&1 + 1))

      message =
        if garbage = Elixir.Agent.get(:mta_garbage, &Enum.at(&1, tool_count)) do
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [%{"id" => "c#{tool_count}", "type" => "function", "function" => %{"name" => "bash", "arguments" => garbage}}]
          }
        else
          %{"role" => "assistant", "content" => "giving up on that"}
        end

      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_mta_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    # Three different malformed strings - never the same one twice, so plain repetition (exact
    # args match) could never have caught this even if it fired on the FIRST call, and any test
    # that passed only because the args happened to repeat wouldn't prove the fix.
    {:ok, _} = Elixir.Agent.start_link(fn -> ["{not json", "{also bad", "nope at all"] end, name: :mta_garbage)
    {:ok, _} = Elixir.Agent.start_link(fn -> 0 end, name: :mta_turns)

    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"})

    agent = %Agent{
      name: "worker",
      model: "mock",
      system_prompt: "hi",
      tools: ["bash"],
      auto_approve: ["*"],
      # The real default (Runtime falls back to 250 when this is nil) - the point of the test
      # is that the guard, not the iteration cap, is what stops the run.
      max_iterations: nil
    }

    Config.put_agent(agent)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{agent: agent, cwd: home}
  end

  test "three consecutive malformed calls to the same tool stop the run near iteration 3, not 250", %{agent: agent, cwd: cwd} do
    {:ok, _reply, _messages} = Runtime.converse(agent, "go", cwd: cwd)

    turns = Elixir.Agent.get(:mta_turns, & &1)
    assert turns <= 4, "expected the loop guard to cut the run short, but it ran #{turns} model turns"
  end
end

defmodule Pepe.Agent.MicroCompactionIntegrationTest do
  @moduledoc """
  `agent.micro_compaction: true` actually engages `Compaction.micro_compact/4` from inside
  the real `Runtime.run/3` loop, and the load-bearing invariant it depends on
  (`runtime.ex`'s `to_send` vs `messages` split) survives several turns of it: the
  persisted/returned history keeps growing turn over turn, never shrinking, even while
  what's SENT to the model is folded differently once the window fills.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.MicroCompaction
  alias Pepe.Agent.Runtime
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.LLM.Message

  defmodule EchoPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = read_body(conn)
      n = Elixir.Agent.get_and_update(:mci_turn, fn c -> {c + 1, c + 1} end)

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => "reply #{n}"}, "finish_reason" => "stop"}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_mci_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, _} = Elixir.Agent.start_link(fn -> 0 end, name: :mci_turn)
    server = start_supervised!({Bandit, plug: EchoPlug, port: 0, scheme: :http})
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    # A small window so a handful of turns pushes it over the compaction threshold without a
    # huge fixture.
    model = %Model{name: "m", base_url: "http://localhost:#{port}", api_key: "test", model: "id", context_window: 100}

    agent = %Agent{
      name: "micro",
      model: "m",
      system_prompt: "hi",
      tools: [],
      max_iterations: 3,
      micro_compaction: true
    }

    Pepe.Config.put_model(model)
    Pepe.Config.put_agent(agent)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{agent: agent}
  end

  test "the persisted history grows every turn and never shrinks, even once micro-compaction kicks in", %{agent: agent} do
    key = "test-session-#{System.unique_integer([:positive])}"

    messages = [Message.system(Pepe.Agent.Workspace.system_prompt(agent))]

    {final_messages, lengths} =
      Enum.reduce(1..6, {messages, []}, fn i, {msgs, lens} ->
        turn_input = msgs ++ [Message.user("question #{i} " <> String.duplicate("x", 80))]

        {:ok, _content, returned} = Runtime.run(agent, turn_input, session_key: key)

        {returned, lens ++ [length(returned)]}
      end)

    # Strictly increasing: the persisted list is never shrunk by compaction, turn over turn -
    # exactly the invariant `to_send`/`messages` in runtime.ex's loop/7 exists to protect.
    assert lengths == Enum.sort(lengths)
    assert Enum.uniq(lengths) == lengths

    # And micro-compaction really did engage at some point across these turns (the window is
    # tiny), not silently falling through to a no-op.
    assert MicroCompaction.get(key) != nil

    # The full, uncompacted conversation is still all there - nothing was ever dropped from
    # the persisted history, only from what got SENT to the model.
    assert length(final_messages) == 1 + 6 * 2
  end
end

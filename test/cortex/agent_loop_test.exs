defmodule Cortex.AgentLoopTest do
  use ExUnit.Case, async: false

  alias Cortex.Agent.Runtime
  alias Cortex.Config.Agent
  alias Cortex.Config.Model
  alias Cortex.LLM

  defmodule TextSink do
    @moduledoc false
    def start, do: spawn(fn -> loop("") end)
    def add(pid, text), do: send(pid, {:add, text})

    def value(pid) do
      ref = make_ref()
      send(pid, {:get, self(), ref})

      receive do
        {^ref, v} -> v
      after
        1000 -> ""
      end
    end

    defp loop(acc) do
      receive do
        {:add, text} ->
          loop(acc <> text)

        {:get, from, ref} ->
          send(from, {ref, acc})
          loop(acc)
      end
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, server} = Bandit.start_link(plug: Cortex.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    model = %Model{
      name: "mock",
      base_url: "http://localhost:#{port}",
      api_key: "test",
      model: "mock-model"
    }

    on_exit(fn -> Process.exit(server, :normal) end)
    %{model: model}
  end

  test "non-streaming chat returns assembled content", %{model: model} do
    {:ok, result} = LLM.chat(model, [%{"role" => "user", "content" => "hi"}])
    assert result.content == "Hello from the mock!"
    assert result.tool_calls == []
    assert result.finish_reason == "stop"
  end

  test "streaming chat assembles deltas and invokes callback", %{model: model} do
    sink = TextSink.start()

    {:ok, result} =
      LLM.stream_chat(model, [%{"role" => "user", "content" => "hi"}], fn text ->
        TextSink.add(sink, text)
      end)

    assert result.content == "Hello from the mock!"
    assert TextSink.value(sink) == "Hello from the mock!"
  end

  test "agent loop executes a tool call and threads the result back", %{model: model} do
    # The mock reads "note.txt" (relative), which resolves into the agent's
    # persistent workspace — so seed the file there.
    home = Path.join(System.tmp_dir!(), "cortex_loop_#{System.unique_integer([:positive])}")
    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
    end)

    workspace = Cortex.Agent.Workspace.dir("tester")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "note.txt"), "secret contents")

    agent = %Agent{
      name: "tester",
      model: "mock",
      system_prompt: "You are a tester.",
      tools: ["read_file"],
      max_iterations: 5
    }

    events = self()

    {:ok, content, messages} =
      Runtime.converse(agent, "please read note.txt",
        model: model,
        on_event: fn ev -> send(events, {:ev, ev}) end
      )

    assert content =~ "secret contents"
    assert Enum.any?(messages, &(&1["role"] == "tool" and &1["content"] =~ "secret contents"))
    assert_received {:ev, {:tool_call, "read_file", _}}
    assert_received {:ev, {:tool_result, "read_file", _}}
  end
end

defmodule Pepe.Agent.OneshotHooksTest do
  @moduledoc """
  `Pepe.Agent.oneshot/4` (used by `mix pepe run`, `Pepe.Cron`, `Pepe.Watch`, `Pepe.Eval`) used
  to skip `Pepe.Hooks` entirely - `Runtime.converse/3` alone never touched it, so neither the
  built-in PII/LLM/HTTP/Presidio redaction nor a plugin content-mutation hook ran on this
  surface, only on a session-backed one. Found live while testing a plugin hook against a
  real local model through `mix pepe chat` (worked) vs `mix pepe run` (silently didn't).
  """
  use ExUnit.Case, async: false

  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    home = Path.join(System.tmp_dir!(), "pepe_oneshot_hooks_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    # Two separate hooks, each on a single stage, so the outbound test's assertion isn't
    # also driven off the tool-call path the inbound test deliberately triggers.
    File.write!(Path.join([home, "plugins", "outbound_marker.exs"]), """
    defmodule OneshotHooksTest.OutboundMarker do
      @behaviour Pepe.Hooks.Hook
      def name, do: "outbound_marker"
      def stages, do: [:outbound]
      def run(:outbound, text, _settings, _ctx), do: {:ok, "[MUTATED] " <> text}
    end
    """)

    File.write!(Path.join([home, "plugins", "inbound_marker.exs"]), """
    defmodule OneshotHooksTest.InboundMarker do
      @behaviour Pepe.Hooks.Hook
      def name, do: "inbound_marker"
      def stages, do: [:inbound]
      def run(:inbound, text, _settings, _ctx), do: {:ok, text <> " read"}
    end
    """)

    Pepe.Config.put_model(%Model{
      name: "mock",
      base_url: "http://localhost:#{port}",
      api_key: "test",
      model: "mock-model"
    })

    Pepe.Config.put_agent(%Agent{
      name: "outbound",
      system_prompt: "x",
      tools: [],
      model: "mock",
      hooks: ["outbound_marker"]
    })

    Pepe.Config.put_agent(%Agent{
      name: "inbound",
      system_prompt: "x",
      tools: ["read_file"],
      model: "mock",
      hooks: ["inbound_marker"]
    })

    Pepe.Config.put_agent(%Agent{name: "plain", system_prompt: "x", tools: [], model: "mock", hooks: []})

    workspace = Pepe.Agent.Workspace.dir("inbound")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "note.txt"), "secret contents")

    :ok
  end

  test "the final reply is outbound-hook-transformed, not the raw model output" do
    assert {:ok, "[MUTATED] Hello from the mock!", _msgs} = Pepe.Agent.oneshot("outbound", "hi")
  end

  test "the prompt is inbound-hook-transformed before it ever reaches the model" do
    # MockLLM answers a tool call whenever any user message contains "read" - "hi" alone
    # doesn't, so seeing the tool actually get called proves the model saw the hook's
    # mutated "hi read", not the raw "hi".
    assert {:ok, _reply, msgs} = Pepe.Agent.oneshot("inbound", "hi")
    assert Enum.any?(msgs, &(&1["role"] == "tool" and &1["content"] =~ "secret contents"))
  end

  test "an agent with no hooks is unaffected" do
    assert {:ok, "Hello from the mock!", _msgs} = Pepe.Agent.oneshot("plain", "hi")
  end
end

defmodule Pepe.Agent.AuxModelMeteringTest do
  @moduledoc """
  Every LLM call outside the main turn loop - compaction's summarizer, the llm_redact
  hook - must meter the same as any other call, or its cost silently disappears from
  the dashboard/billing while still being real spend. Covers the two highest-frequency
  offenders found in an audit (llm_redact runs on every message once enabled;
  compaction runs on every long conversation).
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Compaction
  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.LLM.Message

  defmodule OkPlug do
    @moduledoc false
    import Plug.Conn

    def init(reply), do: reply

    def call(conn, reply) do
      {:ok, _body, conn} = read_body(conn)
      message = %{"role" => "assistant", "content" => reply}

      payload = %{
        "choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 50, "completion_tokens" => 20, "total_tokens" => 70}
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_auxmeter_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp mock_model(reply) do
    {:ok, server} = Bandit.start_link(plug: {OkPlug, reply}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)
    %Model{name: "m", base_url: "http://localhost:#{port}", api_key: "x", model: "id", context_window: 100}
  end

  test "compact_now meters the summarizing call to the given agent" do
    model = mock_model("SUMMARY: shipped Friday.")
    Config.put_agent(%Config.Agent{name: "assistant", tools: []})
    agent = Config.get_agent("assistant")

    messages =
      [Message.system("you help")] ++
        Enum.map(1..8, fn i -> Message.user(String.duplicate("word ", 40) <> "turn #{i}") end)

    assert {:ok, _compacted, _summary} = Compaction.compact_now(messages, model, agent.name)

    entries = Pepe.Usage.Log.entries(Pepe.Project.of(agent.name))
    assert Enum.any?(entries, &(&1["agent"] == agent.name and &1["model"] == "m"))
  end

  test "compact_now with no agent_name still compacts, just doesn't meter" do
    model = mock_model("SUMMARY: shipped Friday.")

    messages =
      [Message.system("you help")] ++
        Enum.map(1..8, fn i -> Message.user(String.duplicate("word ", 40) <> "turn #{i}") end)

    assert {:ok, _compacted, _summary} = Compaction.compact_now(messages, model)
  end

  test "the llm_redact hook meters its call to the agent carried in ctx" do
    model = mock_model(~s({"redacted": "hi [NAME]", "map": [{"fake": "[NAME]", "real": "Ana", "type": "name"}]}))
    Config.put_model(model)
    Config.put_agent(%Config.Agent{name: "support", tools: [], hooks: ["llm_redact"]})
    agent = Config.get_agent("support")
    Config.put_hook_settings("llm_redact", %{"model" => "m"})

    {_text, _entries} = Pepe.Hooks.transform(:inbound, "hi Ana", agent)

    entries = Pepe.Usage.Log.entries(Pepe.Project.of(agent.name))
    assert Enum.any?(entries, &(&1["agent"] == agent.name and &1["model"] == "m"))
  end
end

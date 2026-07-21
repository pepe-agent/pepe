defmodule Pepe.PiiToolResultTest do
  @moduledoc """
  End-to-end proof that PII surfaced by a TOOL (not typed by the human) also never
  reaches the model, and never lands unredacted on disk (session history or a
  spilled tool-output file) - only the final human-facing reply gets it restored.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @cpf "529.982.247-25"

  # First call: ask for a tool. Second call (once it sees a "tool" message): echo
  # back exactly what the tool result said, so outbound restore has tokens to work with.
  defmodule ToolCallLLM do
    import Plug.Conn

    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, body, conn} = read_body(conn)
      messages = Jason.decode!(body)["messages"]
      last = List.last(messages)

      message =
        if last["role"] == "tool" do
          send(pid, {:model_saw_tool_result, last["content"]})
          %{"role" => "assistant", "content" => "Found: #{last["content"]}"}
        else
          tool_call = %{
            "id" => "call_1",
            "type" => "function",
            "function" => %{"name" => "bash", "arguments" => ~s({"command":"echo 'patient CPF #{"529.982.247-25"}'"})}
          }

          %{"role" => "assistant", "content" => nil, "tool_calls" => [tool_call]}
        end

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => message, "finish_reason" => if(last["role"] == "tool", do: "stop", else: "tool_calls")}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    {:ok, server} = Bandit.start_link(plug: {ToolCallLLM, self()}, scheme: :http, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    home = Path.join(System.tmp_dir!(), "pepe_piitool_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    Config.put_hook_settings("pii_redact", %{"packs" => ["br", "intl"]})
    Config.put_model(%Model{name: "mock", base_url: "http://127.0.0.1:#{port}", api_key: "x", model: "m"})
    # No human on this surface, so what may run unattended has to be said out loud. It used
    # to run anyway, which is the hole this now closes.
    Config.put_agent(%Agent{
      name: "dbagent",
      hooks: ["pii_redact"],
      model: "mock",
      tools: ["bash"],
      auto_approve: ["*"]
    })

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "PII in a tool's own output never reaches the model, and comes back restored" do
    {:ok, reply} = Pepe.Agent.chat("piitool:1", "dbagent", "query the patient database")

    assert_received {:model_saw_tool_result, seen}
    refute seen =~ @cpf
    assert seen =~ "[CPF_1]"

    assert reply =~ @cpf
    refute reply =~ "[CPF_1]"
  end

  test "the session's persisted history never carries the raw value either" do
    {:ok, _reply} = Pepe.Agent.chat("piitool:2", "dbagent", "query the patient database")

    history = Pepe.Agent.Session.history("piitool:2")
    tool_msg = Enum.find(history, &(Map.get(&1, "role") == "tool"))

    refute tool_msg["content"] =~ @cpf
    assert tool_msg["content"] =~ "[CPF_1]"
  end

  test "a spilled tool-output file never carries the raw value either" do
    big_cpf_blob = "CPF #{@cpf} " <> String.duplicate("x", 20_000)

    workspace = Path.join(Pepe.Agent.Workspace.dir("dbagent"), "tmp")

    ctx = %{agent: Config.get_agent("dbagent")}

    result =
      Pepe.Tools.execute(%{"function" => %{"name" => "bash", "arguments" => Jason.encode!(%{"command" => "echo '#{big_cpf_blob}'"})}}, ctx)

    refute result =~ @cpf
    assert result =~ "[CPF_1]"
    assert result =~ "truncated"

    spilled = workspace |> File.ls!() |> Enum.map(&File.read!(Path.join(workspace, &1)))
    assert Enum.any?(spilled, &(&1 =~ "[CPF_1]"))
    refute Enum.any?(spilled, &(&1 =~ @cpf))
  end
end

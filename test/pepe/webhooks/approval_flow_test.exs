defmodule Pepe.Webhooks.ApprovalFlowTest do
  @moduledoc """
  The whole path of a typed permission answer on a webhook channel: the agent wants to write a
  file, the question is asked in the conversation, and the next message either settles it
  (and never reaches the agent) or, from someone who may not answer, is just a message.
  """
  use ExUnit.Case, async: false

  alias Pepe.Webhooks.Lane

  @moduletag :capture_log

  defmodule FakeProvider do
    @moduledoc false
    def name, do: "fake"

    def deliver(_entry, to, text) do
      send(Pepe.Webhooks.ApprovalFlowTest.pid(), {:delivered, to, text})
      :ok
    end
  end

  # First turn: asks to write the file named in the user's message. After the tool's result
  # (or its refusal): says what happened.
  defmodule WriterLLM do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)
      last = List.last(req["messages"])

      send(Pepe.Webhooks.ApprovalFlowTest.pid(), {:llm_saw, last["role"], last["content"]})

      if last["role"] == "tool" do
        respond(conn, req["stream"] == true, "tool said: " <> to_string(last["content"]), nil)
      else
        path = Pepe.Webhooks.ApprovalFlowTest.target()
        args = Jason.encode!(%{"path" => path, "content" => "hello"})

        call = %{"id" => "call_1", "type" => "function", "function" => %{"name" => "write_file", "arguments" => args}}

        if String.contains?(to_string(last["content"]), "write it"),
          do: respond(conn, req["stream"] == true, nil, [call]),
          else: respond(conn, req["stream"] == true, "ok: " <> to_string(last["content"]), nil)
      end
    end

    defp respond(conn, false, content, calls) do
      message = %{"role" => "assistant", "content" => content}
      message = if calls, do: Map.put(message, "tool_calls", calls), else: message
      finish = if calls, do: "tool_calls", else: "stop"

      payload = %{
        "id" => "c",
        "object" => "chat.completion",
        "choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish}]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end

    defp respond(conn, true, content, calls) do
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
      delta = if calls, do: %{"tool_calls" => calls}, else: %{"content" => content}
      first = %{"choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => nil}]}
      stop = %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => if(calls, do: "tool_calls", else: "stop")}]}

      for c <- ["data: #{Jason.encode!(first)}\n\n", "data: #{Jason.encode!(stop)}\n\n", "data: [DONE]\n\n"] do
        {:ok, _} = chunk(conn, c)
      end

      conn
    end
  end

  def pid, do: Agent.get(:approval_flow_pid, & &1)
  def target, do: Agent.get(:approval_flow_target, & &1)

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    test_pid = self()
    {:ok, _} = Agent.start_link(fn -> test_pid end, name: :approval_flow_pid)

    target = Path.join(System.tmp_dir!(), "approval_flow_#{System.unique_integer([:positive])}.txt")
    {:ok, _} = Agent.start_link(fn -> target end, name: :approval_flow_target)

    {:ok, llm} = Bandit.start_link(plug: WriterLLM, port: 0, startup_log: false)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(llm)

    home = Path.join(System.tmp_dir!(), "pepe_approval_flow_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    config = %{
      "default_agent" => "acme/writer",
      "models" => %{"mock" => %{"base_url" => "http://localhost:#{port}", "api_key" => "x", "model" => "mock-model"}},
      "companies" => %{"acme" => %{}},
      "agents" => %{"acme/writer" => %{"model" => "mock", "system_prompt" => "You write.", "tools" => ["write_file"]}}
    }

    File.write!(Path.join(home, "config.json"), Jason.encode!(config))

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      File.rm(target)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)
    %{target: target}
  end

  defp entry(trainers) do
    %{"slug" => "flow", "provider" => "fake", "agent" => "acme/writer", "mode" => "support", "trainers" => trainers}
  end

  defp submit(entry, from, text) do
    key = Pepe.Webhooks.session_key(entry, from)
    job = %{entry: entry, mod: FakeProvider, message: %{from: from, text: text, id: nil, name: nil, media: nil}, callers: [self()]}
    assert :ok = Lane.submit(key, job)
  end

  test "a typed allow runs the call, and is not a message for the agent", %{target: target} do
    entry = entry(["boss"])
    submit(entry, "boss", "please write it")

    assert_receive {:delivered, "boss", question}, 10_000
    assert question =~ "write_file"
    assert question =~ "allow"
    refute File.exists?(target)

    submit(entry, "boss", "allow")

    assert_receive {:delivered, "boss", "tool said: " <> _}, 10_000
    assert File.read!(target) == "hello"
    # "allow" went to the approval, never to the model.
    refute_received {:llm_saw, "user", "allow"}
  end

  test "a typed deny refuses the call, and the agent is told", %{target: target} do
    entry = entry(["boss"])
    submit(entry, "boss", "please write it")
    assert_receive {:delivered, "boss", _question}, 10_000

    submit(entry, "boss", "deny")

    assert_receive {:delivered, "boss", "tool said: " <> told}, 10_000
    refute File.exists?(target)
    assert told =~ ~r/not|denied|refus|authoriz/i
  end

  test "without named approvers nothing is asked, and the call is refused as before", %{target: target} do
    entry = entry(nil)
    submit(entry, "boss", "please write it")

    assert_receive {:delivered, "boss", "tool said: " <> _}, 10_000
    refute File.exists?(target)
    refute_received {:delivered, "boss", "Allow me to run" <> _}
  end
end

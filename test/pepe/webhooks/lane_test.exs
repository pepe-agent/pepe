defmodule Pepe.Webhooks.LaneTest do
  @moduledoc """
  Inbound messages of one conversation reach the agent in the order they were received, and
  conversations never wait for each other.

  The case that motivated it: a voice note is a download and a transcription, a text message
  is instant, and they used to race - the question sent after the note was answered before the
  note had joined the conversation. Here a file's download is held open by the test, so "the
  note is still being fetched" is a fact the test controls rather than a timing it hopes for.
  """
  use ExUnit.Case, async: false

  alias Pepe.Webhooks.Dedup
  alias Pepe.Webhooks.Lane

  @moduletag :capture_log

  # A channel whose file downloads wait for the test to say go, and which reports every reply.
  defmodule FakeProvider do
    @moduledoc false
    def name, do: "fake"

    def deliver(_entry, to, text) do
      send(Pepe.Webhooks.LaneTest.pid(), {:delivered, to, text})
      :ok
    end

    def fetch_media(_entry, %{ref: {:wait, id, bytes}}) do
      send(Pepe.Webhooks.LaneTest.pid(), {:fetching, id, self()})

      receive do
        {:release, ^id} -> {:ok, bytes}
      end
    end

    def fetch_media(_entry, %{ref: :crash}), do: raise("the download blew up")
  end

  # Answers with what it was asked, and reports what it was asked, in the order it was asked.
  defmodule EchoLLM do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)

      asked =
        req["messages"]
        |> Enum.filter(&(&1["role"] == "user" and is_binary(&1["content"])))
        |> Enum.reject(&String.starts_with?(&1["content"], "<system-reminder>"))
        |> List.last()
        |> Map.fetch!("content")

      send(Pepe.Webhooks.LaneTest.pid(), {:llm_asked, asked})
      reply = "echo: " <> asked

      if req["stream"] == true do
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        delta = %{"choices" => [%{"index" => 0, "delta" => %{"content" => reply}, "finish_reason" => nil}]}
        stop = %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]}

        for chunk <- ["data: #{Jason.encode!(delta)}\n\n", "data: #{Jason.encode!(stop)}\n\n", "data: [DONE]\n\n"] do
          {:ok, _} = chunk(conn, chunk)
        end

        conn
      else
        payload = %{
          "id" => "cmpl-1",
          "object" => "chat.completion",
          "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => reply}, "finish_reason" => "stop"}]
        }

        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
      end
    end
  end

  def pid, do: Agent.get(:lane_test_pid, & &1)

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    test_pid = self()
    {:ok, _} = Agent.start_link(fn -> test_pid end, name: :lane_test_pid)

    {:ok, llm} = Bandit.start_link(plug: EchoLLM, port: 0, startup_log: false)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(llm)

    home = Path.join(System.tmp_dir!(), "pepe_lane_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    config = %{
      "default_agent" => "acme/support",
      "models" => %{"mock" => %{"base_url" => "http://localhost:#{port}", "api_key" => "x", "model" => "mock-model"}},
      "companies" => %{"acme" => %{}},
      "agents" => %{"acme/support" => %{"model" => "mock", "system_prompt" => "You help.", "tools" => []}}
    }

    File.write!(Path.join(home, "config.json"), Jason.encode!(config))

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    :ok
  end

  defp entry, do: %{"slug" => "lane", "provider" => "fake", "agent" => "acme/support", "mode" => "support"}

  defp job(from, text, media \\ nil) do
    %{
      entry: entry(),
      mod: FakeProvider,
      message: %{from: from, text: text, id: nil, name: nil, media: media},
      callers: [self()]
    }
  end

  defp key(from), do: Pepe.Webhooks.session_key(entry(), from)

  defp note(id, text), do: %{kind: "document", ref: {:wait, id, text}, filename: "note.txt", mime: "text/plain", size: nil}

  describe "one conversation" do
    test "a message sent after a slow attachment does not overtake it" do
      assert :ok = Lane.submit(key("u1"), job("u1", "the note", note(:a, "DOC-CONTENT")))
      task = await_fetch(:a)

      assert :ok = Lane.submit(key("u1"), job("u1", "and my question"))

      # The question is ready and waiting; nothing has reached the agent yet.
      refute_receive {:llm_asked, _}, 100

      release(task, :a)

      assert_receive {:llm_asked, first}, 5_000
      assert first =~ "DOC-CONTENT"
      assert_receive {:llm_asked, "and my question"}, 5_000

      assert_receive {:delivered, "u1", "echo: " <> _}, 5_000
      assert_receive {:delivered, "u1", "echo: and my question"}, 5_000
    end

    test "messages that need no waiting keep their order too" do
      for n <- 1..5, do: assert(:ok = Lane.submit(key("u2"), job("u2", "message #{n}")))

      for n <- 1..5 do
        expected = "message #{n}"
        assert_receive {:llm_asked, ^expected}, 5_000
      end
    end

    test "an attachment whose download crashes is told to the sender and does not wedge the messages behind it" do
      assert :ok = Lane.submit(key("u3"), job("u3", "", %{kind: "document", ref: :crash}))
      assert :ok = Lane.submit(key("u3"), job("u3", "still here"))

      assert_receive {:delivered, "u3", told}, 5_000
      assert told =~ "couldn't download"

      assert_receive {:llm_asked, "still here"}, 5_000
      assert_receive {:delivered, "u3", "echo: still here"}, 5_000
    end

    test "a job that never resolves is stopped after its deadline, and the next one still runs" do
      prev = Application.get_env(:pepe, :webhook_lane_deadline_ms)
      Application.put_env(:pepe, :webhook_lane_deadline_ms, 50)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:pepe, :webhook_lane_deadline_ms, prev),
          else: Application.delete_env(:pepe, :webhook_lane_deadline_ms)
      end)

      assert :ok = Lane.submit(key("u6"), job("u6", "stuck", note(:d, "never released")))
      task = await_fetch(:d)

      assert :ok = Lane.submit(key("u6"), job("u6", "still gets through"))

      # The stuck job's own task never calls `release/2` - the deadline is what ends it.
      assert_receive {:llm_asked, "still gets through"}, 5_000
      assert_receive {:delivered, "u6", "echo: still gets through"}, 5_000
      refute Process.alive?(task)
    end

    test "the wait is bounded: past fifty waiting messages, the rest are refused" do
      assert :ok = Lane.submit(key("u4"), job("u4", "block", note(:b, "x")))
      task = await_fetch(:b)

      for n <- 1..50, do: assert(:ok = Lane.submit(key("u4"), job("u4", "queued #{n}")))
      assert {:error, :full} = Lane.submit(key("u4"), job("u4", "one too many"))

      # Another conversation is unaffected by this one being full.
      assert :ok = Lane.submit(key("u5"), job("u5", "fine"))
      assert_receive {:delivered, "u5", "echo: fine"}, 5_000

      # Nothing is to be answered for the fifty; end the lane instead of letting them run.
      [{lane, _}] = Registry.lookup(Pepe.Webhooks.LaneRegistry, key("u4"))
      Process.exit(task, :kill)
      :ok = DynamicSupervisor.terminate_child(Pepe.Webhooks.LaneSup, lane)
    end
  end

  describe "different conversations" do
    test "one waiting on a download does not hold the other up" do
      assert :ok = Lane.submit(key("slow"), job("slow", "the note", note(:c, "SLOW")))
      task = await_fetch(:c)

      assert :ok = Lane.submit(key("fast"), job("fast", "quick question"))

      assert_receive {:llm_asked, "quick question"}, 5_000
      assert_receive {:delivered, "fast", "echo: quick question"}, 5_000
      refute_received {:delivered, "slow", _}

      release(task, :c)
      assert_receive {:delivered, "slow", _}, 5_000
    end
  end

  describe "Pepe.Webhooks.Dedup" do
    test "the second sighting of an id on a connection is a duplicate" do
      refute Dedup.seen?("conn", "m1")
      assert Dedup.seen?("conn", "m1")
    end

    test "another connection's identical id is its own message" do
      refute Dedup.seen?("conn-a", "same")
      refute Dedup.seen?("conn-b", "same")
    end

    test "a message with no id is never a duplicate" do
      refute Dedup.seen?("conn", nil)
      refute Dedup.seen?("conn", nil)
      refute Dedup.seen?("conn", "")
      refute Dedup.seen?("conn", "")
    end

    test "reset forgets what was seen" do
      refute Dedup.seen?("conn", "again")
      Dedup.reset()
      refute Dedup.seen?("conn", "again")
    end
  end

  # The download waits in a task of its own, which says who it is when it starts waiting.
  defp await_fetch(id) do
    assert_receive {:fetching, ^id, task}, 5_000
    task
  end

  defp release(task, id), do: send(task, {:release, id})
end

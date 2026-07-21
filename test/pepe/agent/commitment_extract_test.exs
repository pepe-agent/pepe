defmodule Pepe.Agent.CommitmentExtractTest do
  @moduledoc """
  Drives `Pepe.Agent.CommitmentExtract` through a real `Session` turn against two mock
  model servers (main + utility), the same two-server pattern
  `session_midrun_fold_test.exs` uses for its own classifier. Covers the parts that
  matter most: off by default, the free pre-filter genuinely skipping the model call,
  a real extraction landing in the right state, and a fabricated `source_excerpt`
  never reaching storage.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  defmodule MainPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, _body, conn} = read_body(conn)
      message = %{"role" => "assistant", "content" => Keyword.fetch!(opts, :reply)}
      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  # The same `utility_model` connection also serves session-title generation (turn 1
  # always tries to name the conversation) - distinguish a real commitment-extraction
  # call by a marker unique to its prompt, so a title-generation hit doesn't get
  # mistaken for one.
  defmodule UtilityPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)

      content =
        if String.contains?(body, "source_excerpt") do
          send(Keyword.fetch!(opts, :test_pid), :utility_hit)
          Keyword.fetch!(opts, :reply)
        else
          "a title"
        end

      message = %{"role" => "assistant", "content" => content}
      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_commit_extract_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp start_plug(mod, opts) do
    {:ok, server} = Bandit.start_link(plug: {mod, opts}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)
    port
  end

  defp put_main(reply) do
    port = start_plug(MainPlug, reply: reply)
    Config.put_model(%Model{name: "main-mock", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
  end

  defp put_utility(reply) do
    port = start_plug(UtilityPlug, reply: reply, test_pid: self())
    Config.put_model(%Model{name: "utility-mock", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    "utility-mock"
  end

  defp put_agent(opts) do
    Config.put_agent(%Agent{
      name: "main",
      model: "main-mock",
      tools: [],
      commitments: Keyword.get(opts, :commitments, true),
      utility_model: Keyword.get(opts, :utility_model)
    })
  end

  defp new_key, do: "test:commitments:#{System.unique_integer([:positive])}"

  defp wait_until(fun, tries \\ 60) do
    cond do
      fun.() -> true
      tries <= 0 -> false
      true -> Process.sleep(25) && wait_until(fun, tries - 1)
    end
  end

  test "off by default: no utility call, nothing stored, even with a clear promise" do
    put_main("Let me check the deploy and I'll tell you tomorrow.")
    utility = put_utility(~s({"commitment":true,"who":"agent","text":"x","source_excerpt":"x","due_when":"tomorrow","confidence":0.9}))
    put_agent(commitments: false, utility_model: utility)
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    assert {:ok, _} = Session.chat(key, "please check the deploy")
    refute_receive :utility_hit, 300
    assert Config.commitments() == []
  end

  test "pre-filter: a turn with no time reference never calls the utility model" do
    put_main("Sure, I can help with that.")
    utility = put_utility(~s({"commitment":false}))
    put_agent(utility_model: utility)
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    assert {:ok, _} = Session.chat(key, "can you help me with something")
    refute_receive :utility_hit, 300
    assert Config.commitments() == []
  end

  test "a genuine, high-confidence agent promise is stored and scheduled" do
    reply = "Let me check the deploy and I'll tell you tomorrow."
    put_main(reply)

    extraction =
      Jason.encode!(%{
        "commitment" => true,
        "who" => "agent",
        "text" => "check the deploy and report back",
        "source_excerpt" => reply,
        "due_when" => "tomorrow",
        "confidence" => 0.9
      })

    utility = put_utility(extraction)
    put_agent(utility_model: utility)
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    assert {:ok, ^reply} = Session.chat(key, "please check the deploy")
    assert_receive :utility_hit, 2_000
    assert wait_until(fn -> Config.commitments() != [] end)

    [commitment] = Config.commitments()
    assert commitment.state == "scheduled"
    assert commitment.origin_type == "agent_promise"
    assert commitment.text == "check the deploy and report back"
    assert is_integer(commitment.due_at)

    # Extraction runs in its own spawned Task (see maybe_extract/1), a fresh process with
    # an empty process dictionary - regression for that Task not tagging its own writes,
    # which used to leave them showing "unknown" in the journal.
    [entry | _] = Pepe.Config.Journal.recent()
    assert entry["source"] == "commitments:extract"
  end

  test "a low-confidence extraction lands awaiting confirmation instead of scheduled" do
    reply = "Sure, I'll look into it tomorrow."
    put_main(reply)

    extraction =
      Jason.encode!(%{
        "commitment" => true,
        "who" => "agent",
        "text" => "look into it",
        "source_excerpt" => reply,
        "due_when" => "tomorrow",
        "confidence" => 0.2
      })

    utility = put_utility(extraction)
    put_agent(utility_model: utility)
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    assert {:ok, ^reply} = Session.chat(key, "please look into it")
    assert_receive :utility_hit, 2_000
    assert wait_until(fn -> Config.commitments() != [] end)

    [commitment] = Config.commitments()
    assert commitment.state == "awaiting_confirmation"
  end

  test "a fabricated source_excerpt (not actually in the transcript) is discarded" do
    put_main("Sure, I'll check that tomorrow.")

    extraction =
      Jason.encode!(%{
        "commitment" => true,
        "who" => "agent",
        "text" => "made up commitment",
        "source_excerpt" => "this sentence was never said by anyone in this conversation",
        "due_when" => "tomorrow",
        "confidence" => 0.95
      })

    utility = put_utility(extraction)
    put_agent(utility_model: utility)
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    assert {:ok, _} = Session.chat(key, "please check that")
    assert_receive :utility_hit, 2_000
    # Give the (should-be-a-no-op) async extraction a moment to finish, then confirm
    # nothing landed - a bounded wait for absence, not an indefinite one.
    refute wait_until(fn -> Config.commitments() != [] end, 20)
  end
end

defmodule Pepe.Agent.AutoTitleTest do
  @moduledoc """
  A session names itself after its first exchange.

  With a `utility_model`, a cheap model writes the name. With none, the opening message is
  trimmed into one. What most needs pinning is that second path, because it is the one every
  install gets by default: it must never reach for the agent's own model (those tokens land
  on somebody's invoice, and nobody asked for them), and it must still leave the sidebar
  readable.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Agent.SessionTitles
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # Answers a naming request with whatever the test parked, and records every request.
  defmodule TitlePlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)
      Elixir.Agent.update(:at_seen, &(&1 ++ [req]))

      content =
        if naming?(req),
          # A plain string answers every naming call the same way (most tests); wrapping it
          # in {:seq, [...]} instead pops one answer per call, so a test can pin a PENDING-
          # then-real-title retry sequence without needing a second mock.
          do: Elixir.Agent.get_and_update(:at_title, &next_title/1),
          else: "sure, here is an answer"

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => content}, "finish_reason" => "stop"}
        ],
        "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 4}
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end

    def naming?(%{"messages" => msgs}) do
      Enum.any?(msgs, &(&1["role"] == "system" and &1["content"] =~ "Name this conversation"))
    end

    defp next_title({:seq, [next | rest]}), do: {next, {:seq, rest}}
    defp next_title({:seq, []}), do: {"", {:seq, []}}
    defp next_title(plain), do: {plain, plain}
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_at_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, _} = Elixir.Agent.start_link(fn -> [] end, name: :at_seen)
    {:ok, _} = Elixir.Agent.start_link(fn -> "Deploying with Docker" end, name: :at_title)
    {:ok, server} = Bandit.start_link(plug: TitlePlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "main", base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"})
    Config.put_model(%Model{name: "cheap", base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "small"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    # Registered last so it runs FIRST: a run still in flight has to be stopped while the config
    # and PEPE_HOME it is running against still exist, or it carries on into the next test and
    # calls that test's mock. See Pepe.Test.Sessions.
    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    :ok
  end

  defp agent!(opts) do
    agent =
      struct(%Agent{name: "worker", model: "main", system_prompt: "hi", tools: [], max_iterations: 3}, opts)

    Config.put_agent(agent)
    agent
  end

  defp key, do: "test:#{System.unique_integer([:positive])}"

  # A session is a supervised process, and Session.chat/3 talks to one that already exists.
  defp chat(key, text, agent) do
    {:ok, _pid} = SessionSupervisor.ensure(key, agent.name)
    Session.chat(key, text)
  end

  # The title lands from a task, after the reply. Wait for it rather than sleeping blind.
  defp await_title(key, tries \\ 40) do
    cond do
      title = SessionTitles.get(key) -> title
      tries == 0 -> nil
      true -> Process.sleep(25) && await_title(key, tries - 1)
    end
  end

  defp namings, do: Elixir.Agent.get(:at_seen, & &1) |> Enum.filter(&TitlePlug.naming?/1)

  test "a conversation names itself after the first exchange, on the utility model" do
    agent = agent!(utility_model: "cheap")
    k = key()

    {:ok, _reply} = chat(k, "how do I deploy this with docker?", agent)

    assert await_title(k) == "Deploying with Docker"

    # On the cheap connection, not the agent's own, and shown both the opening message and
    # the reply it got - naming from the exchange, not a guess from one line.
    assert [call] = namings()
    assert call["model"] == "small"
    assert Enum.any?(call["messages"], &(&1["content"] =~ "docker"))
    assert Enum.any?(call["messages"], &(&1["content"] =~ "sure, here is an answer"))
  end

  test "a PENDING verdict defers naming - a bare greeting doesn't get named from its own reply either" do
    Elixir.Agent.update(:at_title, fn _ -> {:seq, ["PENDING", "Docker deploy help"]} end)
    agent = agent!(utility_model: "cheap")
    k = key()

    {:ok, _} = chat(k, "oi", agent)
    Process.sleep(150)
    assert SessionTitles.get(k) == nil
    assert [_] = namings()

    {:ok, _} = chat(k, "preciso configurar o docker", agent)
    assert await_title(k) == "Docker deploy help"
    assert [_, _] = namings()
  end

  test "once the retry budget is spent, a session is named anyway instead of staying blank forever" do
    Elixir.Agent.update(:at_title, fn _ -> {:seq, ["PENDING", "PENDING", "PENDING"]} end)
    agent = agent!(utility_model: "cheap")
    k = key()

    {:ok, _} = chat(k, "oi", agent)
    Process.sleep(120)
    {:ok, _} = chat(k, "tudo bem?", agent)
    Process.sleep(120)
    {:ok, _} = chat(k, "e você?", agent)
    Process.sleep(150)

    # Exactly 3 attempts: the 4th turn wouldn't even try (Session.@max_naming_tries).
    assert [_, _, _] = namings()
    title = SessionTitles.get(k)
    refute title == nil
    refute title == "PENDING"
  end

  test "a naming attempt already in flight blocks a second one from firing concurrently" do
    agent = agent!(utility_model: "cheap")
    k = key()

    # Simulates the real race this guards: a previous turn's fire-and-forget naming Task
    # (up to ~20s on LLM.chat's own receive_timeout) still running when a later turn's
    # maybe_title/1 checks in - without the lock, SessionTitles.get(k) is nil for both and
    # a second naming call fires right alongside the first.
    Pepe.Store.put(:naming_in_flight, k, true, ttl: 30)

    {:ok, _} = chat(k, "oi", agent)
    Process.sleep(150)

    assert namings() == []
    assert SessionTitles.get(k) == nil
  end

  test "it names the conversation once, not on every turn" do
    agent = agent!(utility_model: "cheap")
    k = key()

    {:ok, _} = chat(k, "first", agent)
    assert await_title(k)
    {:ok, _} = chat(k, "second", agent)
    {:ok, _} = chat(k, "third", agent)
    Process.sleep(100)

    assert [_only_one] = namings()
  end

  test "a name the human chose is never overwritten" do
    agent = agent!(utility_model: "cheap")
    k = key()
    SessionTitles.set(k, "My own name")

    {:ok, _} = chat(k, "hello", agent)
    Process.sleep(150)

    assert SessionTitles.get(k) == "My own name"
    assert namings() == []
  end

  test "with no utility model the conversation is named without one, and costs nothing" do
    # The point of the opt-in: upgrading Pepe must not silently start spending on an install
    # that never asked for it. But the sidebar still needs to read like something, and the
    # first words of what was asked do that for free.
    agent = agent!(utility_model: nil)
    k = key()

    {:ok, _} = chat(k, "how do I deploy this with docker on the server?", agent)
    Process.sleep(150)

    assert SessionTitles.get(k) == "how do I deploy this with docker..."
    assert namings() == []
  end

  test "a utility model naming a connection that does not exist counts as unset" do
    # A typo must not be the thing that starts spending on the expensive model. It also must
    # not cost you your titles.
    agent = agent!(utility_model: "typo")
    k = key()

    # Five words, same length as TitlePlug's fixed reply ("sure, here is an answer") - the
    # trim fallback picks whichever of opening/reply has MORE words (see SessionTitles.trimmed/2),
    # so a tie keeps the opening, pinning this test to the message actually sent rather than
    # the mock's fixed reply text.
    {:ok, _} = chat(k, "a question about my billing", agent)
    Process.sleep(150)

    assert SessionTitles.get(k) == "a question about my billing"
    assert namings() == []
  end

  test "prose instead of a label falls back to the trim" do
    # A paragraph is not a title. This is also the shape of the reasoning-model failure: one
    # that thinks past its budget answers with nothing usable, and the free path catches it.
    Elixir.Agent.update(:at_title, fn _ ->
      "Certainly! Here is a title that captures the essence of your conversation in full."
    end)

    agent = agent!(utility_model: "cheap")
    k = key()

    {:ok, _} = chat(k, "resetting my forgotten password now", agent)
    Process.sleep(150)

    assert SessionTitles.get(k) == "resetting my forgotten password now"
  end

  test "a short opening message is not marked as cut" do
    agent = agent!(utility_model: nil)
    k = key()

    {:ok, _} = chat(k, "docker compose build image now", agent)
    Process.sleep(150)

    assert SessionTitles.get(k) == "docker compose build image now"
  end

  test "a bare greeting defers naming instead of becoming the title - even the reply doesn't stand in for it" do
    # The exact complaint this fixes: a sidebar full of chats all named "oi"/"hey" because
    # the first message was the label. An earlier version of this fix picked whichever of
    # the message/reply had more words, which is itself wrong - the mock's fixed reply
    # ("sure, here is an answer") is not a real topic either, and must not become the title
    # any more than "oi" would.
    agent = agent!(utility_model: nil)
    k = key()

    {:ok, _} = chat(k, "oi", agent)
    Process.sleep(150)

    refute SessionTitles.get(k) == "oi"
    refute SessionTitles.get(k) == "sure, here is an answer"
    assert SessionTitles.get(k) == nil

    # Turn 2: an actually substantive message is what gets used, once it arrives.
    {:ok, _} = chat(k, "preciso configurar o servidor de producao", agent)
    assert await_title(k) == "preciso configurar o servidor de producao"
  end

  test "a title in quotes is unwrapped" do
    Elixir.Agent.update(:at_title, fn _ -> ~s("Docker Deploy Help") end)
    agent = agent!(utility_model: "cheap")
    k = key()

    {:ok, _} = chat(k, "hello", agent)
    assert await_title(k) == "Docker Deploy Help"
  end
end

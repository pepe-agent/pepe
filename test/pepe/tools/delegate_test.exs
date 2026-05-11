defmodule Pepe.Tools.DelegateTest do
  @moduledoc """
  Fan-out: several throwaway workers, at once, each in its own context, and only their
  answers come back.

  Two properties carry the whole design. Speed is the obvious one. The one that matters more
  is that **a worker may read but never act**: three workers running at once are three
  workers that would want to ask the human three questions at once, and "may I run this?" is
  not a question to be asked in triplicate. Fan-out is for finding out; acting stays in the
  one conversation the human is watching.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Tools.Delegate

  # A worker's model: answers with the tools it was actually given, so the test can see what
  # the worker was allowed to hold.
  defmodule WorkerPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)
      Process.sleep(Elixir.Agent.get(:dg_delay, & &1))

      if Elixir.Agent.get(:dg_fail, & &1) do
        # 401 is not transient, so it fails outright rather than being retried.
        throw_401(conn)
      else
        answer(conn, req)
      end
    end

    defp throw_401(conn) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{"error" => %{"message" => "no"}}))
    end

    defp answer(conn, req) do
      names =
        (req["tools"] || [])
        |> Enum.map(& &1["function"]["name"])
        |> Enum.sort()
        |> Enum.join(",")

      task = req["messages"] |> Enum.find(&(&1["role"] == "user")) |> Map.get("content")

      payload = %{
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "did [#{task}] with tools [#{names}]"},
            "finish_reason" => "stop"
          }
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_dg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, _} = Elixir.Agent.start_link(fn -> 0 end, name: :dg_delay)
    {:ok, _} = Elixir.Agent.start_link(fn -> false end, name: :dg_fail)
    {:ok, server} = Bandit.start_link(plug: WorkerPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "m", base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"})

    parent = %Agent{
      name: "lead",
      model: "m",
      system_prompt: "hi",
      # Everything: read-only tools, tools that act, and delegate itself.
      tools: ["read_file", "fetch_url", "web_search", "bash", "write_file", "delegate"],
      max_iterations: 3
    }

    Config.put_agent(parent)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{ctx: %{agent: parent, cwd: home}}
  end

  test "the work is split, and every answer comes back in the order it was asked", %{ctx: ctx} do
    assert {:ok, out} = Delegate.run(%{"tasks" => ["check acme", "check globex", "check initech"]}, ctx)

    assert out =~ "### 1. check acme"
    assert out =~ "### 2. check globex"
    assert out =~ "### 3. check initech"

    # Each worker saw only its own sentence, not the others and not the parent's conversation.
    assert out =~ "did [check acme]"
    assert out =~ "did [check globex]"
  end

  test "a worker may read but never act", %{ctx: ctx} do
    assert {:ok, out} = Delegate.run(%{"tasks" => ["look something up"]}, ctx)

    # It kept what needs no permission...
    assert out =~ "fetch_url"
    assert out =~ "read_file"
    assert out =~ "web_search"

    # ...and was stripped of everything that acts, before it ever started. Three workers
    # asking the human for permission at once is not a thing that should be possible.
    refute out =~ "bash"
    refute out =~ "write_file"

    # And it cannot delegate: without this, one task becomes eight becomes sixty-four.
    refute out =~ "delegate"
  end

  test "they wait at the same time, not one after another", %{ctx: ctx} do
    Elixir.Agent.update(:dg_delay, fn _ -> 300 end)

    {micros, {:ok, _out}} =
      :timer.tc(fn -> Delegate.run(%{"tasks" => ["a", "b", "c", "d"]}, ctx) end)

    ms = div(micros, 1000)

    # Four 300ms workers: 1200ms in series, one wait together. Loose on purpose, so this
    # fails on a regression to serial rather than on a slow machine.
    assert ms < 800, "four 300ms workers took #{ms}ms, which is the serial cost"
  end

  test "it refuses to spend your month in one call", %{ctx: ctx} do
    many = Enum.map(1..12, &"task #{&1}")

    assert {:error, why} = Delegate.run(%{"tasks" => many}, ctx)
    assert why =~ "too many"
  end

  test "delegating as another agent obeys the same allowlist as messaging one", %{ctx: ctx} do
    Config.put_agent(%Agent{name: "researcher", model: "m", system_prompt: "hi", tools: ["fetch_url"]})

    # The parent may not message it, so it may not borrow its identity either. One authority
    # for the act, not a second and weaker one.
    assert {:error, why} = Delegate.run(%{"tasks" => ["go"], "agent" => "researcher"}, ctx)
    assert why =~ "isn't available"

    parent = %{ctx.agent | can_message: ["researcher"]}
    Config.put_agent(parent)

    assert {:ok, out} = Delegate.run(%{"tasks" => ["go"], "agent" => "researcher"}, %{ctx | agent: parent})
    assert out =~ "fetch_url"
  end

  test "a worker that fails is reported, not silently dropped", %{ctx: ctx} do
    # The provider refuses the workers outright.
    Elixir.Agent.update(:dg_fail, fn _ -> true end)

    assert {:ok, out} = Delegate.run(%{"tasks" => ["a", "b"]}, ctx)

    # Both sections are present and both say what happened. A missing section would have read
    # as an empty answer, which is worse than a failure: the parent would summarize a silence.
    assert out =~ "### 1. a"
    assert out =~ "### 2. b"
    assert out =~ "failed"
  end

  test "nothing to do is an error, not an empty fan-out", %{ctx: ctx} do
    assert {:error, _} = Delegate.run(%{"tasks" => []}, ctx)
    assert {:error, _} = Delegate.run(%{"tasks" => ["  "]}, ctx)
    assert {:error, _} = Delegate.run(%{}, ctx)
  end
end

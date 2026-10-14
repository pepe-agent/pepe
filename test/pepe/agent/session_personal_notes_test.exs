defmodule Pepe.Agent.SessionPersonalNotesTest do
  @moduledoc """
  `MEMORY.md` and `USER.md` describe a person, so they reach the prompt of a conversation only
  when that conversation may feed what the agent keeps. A session builds its prompt before the
  first message says whether it may, so a visitor who may not must get it rebuilt without them.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Agent.Workspace
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    home = Path.join(System.tmp_dir!(), "pepe_personal_notes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"})
    Config.put_agent(%Agent{name: "assistant", system_prompt: "x", model: "mock", tools: ["read_file"]})
    dir = Workspace.dir("assistant")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "USER.md"), "The owner is Jho and likes tacos.")
    File.write!(Path.join(dir, "TOOLS.md"), "Reports: run the weekly script.")
    :ok
  end

  defp system_text(key) do
    {:ok, pid} = SessionSupervisor.ensure(key, "assistant")
    %{messages: [%{"role" => "system", "content" => text} | _]} = :sys.get_state(pid)
    text
  end

  test "a new private session starts with the notes about its person" do
    text = system_text("web:notes-#{System.unique_integer([:positive])}")
    assert text =~ "likes tacos"
    assert text =~ "run the weekly script"
  end

  test "a visitor who may not learn gets the prompt rebuilt without them, and keeps the operator's notes" do
    key = "widget:example.com:#{System.unique_integer([:positive])}"
    assert system_text(key) =~ "likes tacos"

    {:ok, _reply} = Session.chat(key, "hello", learn: false)

    text = system_text(key)
    refute text =~ "likes tacos"
    refute text =~ "Write it down as you go"
    assert text =~ "run the weekly script"
  end
end

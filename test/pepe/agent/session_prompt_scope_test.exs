defmodule Pepe.Agent.SessionPromptScopeTest do
  @moduledoc """
  The system prompt a session starts with is built for that conversation: a dashboard or API
  session is one person, so it does not carry the paragraph about telling people apart in a group
  chat, while a chat app session does.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config

  @group "A shared channel can hold more than one person"

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    home = Path.join(System.tmp_dir!(), "pepe_prompt_scope_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Config.put_agent(%Config.Agent{name: "assistant", system_prompt: "x", model: "m", tools: ["read_file"]})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp system_prompt(key) do
    {:ok, pid} = SessionSupervisor.ensure(key, "assistant")
    %{messages: [%{"role" => "system", "content" => text} | _]} = :sys.get_state(pid)
    text
  end

  test "a dashboard session does not carry the group-chat paragraph" do
    refute system_prompt("web:scope-#{System.unique_integer([:positive])}") =~ @group
  end

  test "a Telegram session does" do
    assert system_prompt("telegram:scope-#{System.unique_integer([:positive])}") =~ @group
  end

  test "starting over with /new keeps the prompt of the same kind of conversation" do
    key = "web:scope-#{System.unique_integer([:positive])}"
    system_prompt(key)
    :ok = Pepe.Agent.Session.reset(key)
    {:ok, pid} = SessionSupervisor.ensure(key, "assistant")
    %{messages: [%{"content" => text} | _]} = :sys.get_state(pid)
    refute text =~ @group
  end
end

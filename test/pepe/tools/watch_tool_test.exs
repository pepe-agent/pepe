defmodule Pepe.Tools.WatchTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Tools.Watch, as: Tool

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_wtool_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, ctx: %{agent: %{name: "zak"}, session_key: "telegram:42"}}
  end

  test "create builds a probe watch and captures the telegram origin", %{ctx: ctx} do
    args = %{
      "action" => "create",
      "description" => "site x back",
      "trigger" => "probe",
      "probe_command" => "curl -sf https://x",
      "message" => "✅ back"
    }

    assert {:ok, msg} = Tool.run(args, ctx)
    assert msg =~ "Watch created"

    [w] = Config.watches()

    assert w.trigger == %{
             "type" => "probe",
             "command" => "curl -sf https://x",
             "success" => "exit_zero"
           }

    assert w.on_fire == %{"type" => "template", "text" => "✅ back"}

    assert w.origin == %{
             "channel" => "telegram",
             "bot" => "default",
             "chat_id" => "42",
             "key" => "telegram:42"
           }

    assert w.agent == "zak"
  end

  test "an agent trigger is forced to the slower minimum interval", %{ctx: ctx} do
    args = %{
      "action" => "create",
      "description" => "mood",
      "trigger" => "agent",
      "check_prompt" => "is the client upset?",
      "interval_s" => 10
    }

    assert {:ok, _} = Tool.run(args, ctx)
    assert hd(Config.watches()).interval_s == 300
  end

  test "duplicate conditions are refused", %{ctx: ctx} do
    args = %{
      "action" => "create",
      "description" => "x",
      "trigger" => "probe",
      "probe_command" => "true"
    }

    assert {:ok, _} = Tool.run(args, ctx)
    assert {:error, msg} = Tool.run(args, ctx)
    assert msg =~ "already exists"
  end

  test "list / pause / cancel", %{ctx: ctx} do
    Tool.run(
      %{
        "action" => "create",
        "description" => "x",
        "trigger" => "probe",
        "probe_command" => "true"
      },
      ctx
    )

    id = hd(Config.watches()).id

    assert {:ok, list} = Tool.run(%{"action" => "list"}, ctx)
    assert list =~ id

    assert {:ok, _} = Tool.run(%{"action" => "pause", "id" => id}, ctx)
    assert Config.get_watch(id).state == "paused"

    assert {:ok, _} = Tool.run(%{"action" => "cancel", "id" => id}, ctx)
    assert Config.get_watch(id) == nil
  end

  test "create needs a valid trigger", %{ctx: ctx} do
    assert {:error, _} = Tool.run(%{"action" => "create", "description" => "x"}, ctx)

    assert {:error, msg} =
             Tool.run(%{"action" => "create", "description" => "x", "trigger" => "probe"}, ctx)

    assert msg =~ "probe_command"
  end
end

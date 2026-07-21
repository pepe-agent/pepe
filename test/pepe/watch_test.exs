defmodule Pepe.WatchTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Watch

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_watch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp watch(attrs) do
    struct(%Watch{id: "w1", description: "test", interval_s: 120, max_checks: 3}, attrs)
  end

  describe "persistence" do
    test "put/get/list/delete round-trip" do
      Config.put_watch(watch(id: "w1"))
      Config.put_watch(watch(id: "w2"))

      assert Enum.map(Config.watches(), & &1.id) == ["w1", "w2"]
      assert Config.get_watch("w1").description == "test"

      Config.delete_watch("w1")
      assert Config.get_watch("w1") == nil
      assert Enum.map(Config.watches(), & &1.id) == ["w2"]
    end
  end

  describe "due?/2" do
    test "a fresh pending watch is due; a future next_check is not; non-pending never is" do
      assert Pepe.Watch.due?(watch(next_check: nil), 1000)
      assert Pepe.Watch.due?(watch(next_check: 900), 1000)
      refute Pepe.Watch.due?(watch(next_check: 1100), 1000)
      refute Pepe.Watch.due?(watch(state: "paused", next_check: nil), 1000)
      refute Pepe.Watch.due?(watch(state: "done", next_check: nil), 1000)
    end
  end

  describe "evaluate/1 with a probe trigger" do
    test "a passing probe fires and returns the template text" do
      w =
        watch(
          trigger: %{"type" => "probe", "command" => "exit 0"},
          on_fire: %{"type" => "template", "text" => "✅ up"}
        )

      assert {%Watch{state: "done", checks: 1, next_check: nil}, "✅ up"} =
               Pepe.Watch.evaluate(w)
    end

    test "a failing probe keeps waiting and bumps the check counter" do
      w = watch(trigger: %{"type" => "probe", "command" => "exit 1"})
      assert {%Watch{state: "pending", checks: 1} = w2, nil} = Pepe.Watch.evaluate(w)
      assert is_integer(w2.next_check)
    end

    test "a `contains` probe matches stdout regardless of exit code" do
      w =
        watch(
          trigger: %{
            "type" => "probe",
            "command" => "echo READY",
            "success" => %{"contains" => "READY"}
          },
          on_fire: %{"type" => "template", "text" => "done"}
        )

      assert {%Watch{state: "done"}, "done"} = Pepe.Watch.evaluate(w)
    end

    test "hitting max_checks expires the watch" do
      w = watch(trigger: %{"type" => "probe", "command" => "exit 1"}, checks: 2, max_checks: 3)

      assert {%Watch{state: "expired", checks: 3, next_check: nil}, nil} =
               Pepe.Watch.evaluate(w)
    end
  end
end

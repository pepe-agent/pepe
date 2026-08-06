defmodule PepePluginsTest.Thrower do
  def go, do: throw(:boom)
end

defmodule Pepe.PluginsTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_plugins_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  describe "safe_call/3" do
    test "returns {:ok, result} for a clean call" do
      assert Pepe.Plugins.safe_call(String, :upcase, ["hi"]) == {:ok, "HI"}
    end

    test "returns :error, logged, for a raise" do
      assert Pepe.Plugins.safe_call(String, :to_integer, ["not a number"]) == :error
    end

    test "returns :error for a throw/exit, not a crash" do
      mod = PepePluginsTest.Thrower
      assert Pepe.Plugins.safe_call(mod, :go, []) == :error
    end
  end

  describe "compile timeout" do
    test "a plugin that hangs at compile time is skipped rather than freezing the caller", %{home: home} do
      path = Path.join([home, "plugins", "hangs.exs"])

      File.write!(path, """
      Process.sleep(:infinity)

      defmodule PepePluginsTest.Hangs do
        def name, do: "hangs"
      end
      """)

      {elapsed, mods} = :timer.tc(fn -> Pepe.Plugins.implementing([{:name, 0}]) end)

      refute PepePluginsTest.Hangs in mods
      # Bounded by the compile timeout (5s), not left hanging indefinitely.
      assert elapsed < 6_000_000

      # Cached: a second call within the same mtime doesn't pay the timeout again.
      {elapsed2, _mods} = :timer.tc(fn -> Pepe.Plugins.implementing([{:name, 0}]) end)
      assert elapsed2 < 1_000_000
    end

    test "a plugin that crashes at compile time is skipped, not fatal to others", %{home: home} do
      File.write!(Path.join([home, "plugins", "crashes.exs"]), """
      raise "boom at compile time"
      """)

      File.write!(Path.join([home, "plugins", "fine.exs"]), """
      defmodule PepePluginsTest.Fine do
        def name, do: "fine"
      end
      """)

      mods = Pepe.Plugins.implementing([{:name, 0}])
      assert PepePluginsTest.Fine in mods
    end

    test "still loads a plugin when Pepe.Plugins.TaskSupervisor isn't running - the lightweight CLI-command case", %{
      home: home
    } do
      # Mix.Tasks.Pepe.with_config/1 (agent add, plugin route enable, ...) never starts
      # Pepe.Application at all, so this supervisor genuinely doesn't exist for those
      # commands - found live, running `mix pepe agent add`/`plugin route enable`
      # against a real install with a plugin present: it crashed outright with a
      # GenServer.call on a nonexistent process. compile_with_timeout/1 must fall back to
      # a synchronous compile (no hang-protection, but no crash either) rather than
      # assume the supervisor is always there.
      File.write!(Path.join([home, "plugins", "no_sup.exs"]), """
      defmodule PepePluginsTest.NoSup do
        def name, do: "no_sup"
      end
      """)

      pid = Process.whereis(Pepe.Plugins.TaskSupervisor)
      assert is_pid(pid)
      Supervisor.terminate_child(Pepe.Supervisor, Pepe.Plugins.TaskSupervisor)
      refute Process.whereis(Pepe.Plugins.TaskSupervisor)

      on_exit(fn -> Supervisor.restart_child(Pepe.Supervisor, Pepe.Plugins.TaskSupervisor) end)

      mods = Pepe.Plugins.implementing([{:name, 0}])
      assert PepePluginsTest.NoSup in mods
    end

    test "a plugin that hangs is still bounded by the timeout when Pepe.Plugins.TaskSupervisor isn't running", %{
      home: home
    } do
      # The fallback used to lose hang-protection entirely (a bare synchronous compile)
      # - fixed to spin up its own ephemeral, throwaway Task.Supervisor for the one call
      # instead, so a hung plugin here still times out in ~5s rather than hanging
      # whatever's calling Pepe.Plugins.implementing/1 forever.
      File.write!(Path.join([home, "plugins", "hangs_no_sup.exs"]), """
      Process.sleep(:infinity)

      defmodule PepePluginsTest.HangsNoSup do
        def name, do: "hangs_no_sup"
      end
      """)

      Supervisor.terminate_child(Pepe.Supervisor, Pepe.Plugins.TaskSupervisor)
      on_exit(fn -> Supervisor.restart_child(Pepe.Supervisor, Pepe.Plugins.TaskSupervisor) end)

      {elapsed, mods} = :timer.tc(fn -> Pepe.Plugins.implementing([{:name, 0}]) end)

      refute PepePluginsTest.HangsNoSup in mods
      assert elapsed < 6_000_000
    end

    test "a plugin that throws/exits at compile time doesn't crash the synchronous fallback path", %{home: home} do
      # Normally a throw/exit at a plugin's own top level is caught by
      # compile_with_timeout_supervised/1's Task boundary regardless of whether compile/1
      # itself catches it. The synchronous fallback (no Task, no supervisor) calls
      # straight into compile/1, so it needs its own catch - without one, this exact
      # plugin would crash the calling CLI command outright.
      File.write!(Path.join([home, "plugins", "throws.exs"]), """
      throw(:boom_at_top_level)
      """)

      Supervisor.terminate_child(Pepe.Supervisor, Pepe.Plugins.TaskSupervisor)
      on_exit(fn -> Supervisor.restart_child(Pepe.Supervisor, Pepe.Plugins.TaskSupervisor) end)

      assert Pepe.Plugins.implementing([{:name, 0}]) == []
    end
  end
end

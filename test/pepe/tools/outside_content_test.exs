defmodule Pepe.Tools.OutsideContentTest do
  @moduledoc """
  A plugin that reads somebody else's text (a ticket, a page) says so, and the run then stops
  honoring `auto_approve`, exactly as it does after `fetch_url`. A plugin that says nothing is
  treated as before.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Runtime
  alias Pepe.Permissions

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_outside_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    File.write!(Path.join([home, "plugins", "readers.exs"]), """
    defmodule PepeOutsideTest.TicketReader do
      @behaviour Pepe.Tools.Tool
      import Pepe.Tools.Tool, only: [function: 3]
      def name, do: "read_ticket"
      def outside_content?, do: true
      def spec, do: function("read_ticket", "Read a ticket.", %{"type" => "object", "properties" => %{}})
      def run(_args, _ctx), do: {:ok, "a ticket"}
    end

    defmodule PepeOutsideTest.Calculator do
      @behaviour Pepe.Tools.Tool
      import Pepe.Tools.Tool, only: [function: 3]
      def name, do: "add_numbers"
      def spec, do: function("add_numbers", "Add.", %{"type" => "object", "properties" => %{}})
      def run(_args, _ctx), do: {:ok, "3"}
    end

    defmodule PepeOutsideTest.Liar do
      @behaviour Pepe.Tools.Tool
      import Pepe.Tools.Tool, only: [function: 3]
      def name, do: "read_ticket_no"
      def outside_content?, do: false
      def spec, do: function("read_ticket_no", "Not outside.", %{"type" => "object", "properties" => %{}})
      def run(_args, _ctx), do: {:ok, "x"}
    end
    """)

    # Load the plugin tools so the registry knows them.
    Pepe.Tools.all()
    Permissions.untaint()

    on_exit(fn ->
      Permissions.untaint()
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "a plugin tool that says its result is outside content is treated as one" do
    assert Pepe.Tools.outside_content?("read_ticket")
    assert Runtime.outside_content?("read_ticket")
  end

  test "a plugin tool that says nothing, or says no, is not" do
    refute Pepe.Tools.outside_content?("add_numbers")
    refute Pepe.Tools.outside_content?("read_ticket_no")
    refute Runtime.outside_content?("add_numbers")
  end

  test "an unknown tool is not outside content" do
    refute Pepe.Tools.outside_content?("nothing_by_this_name")
  end

  test "using such a tool taints the run, and a plain one does not" do
    refute Permissions.tainted?(%{})

    Runtime.taint_if_outside("add_numbers")
    refute Permissions.tainted?(%{})

    Runtime.taint_if_outside("read_ticket")
    assert Permissions.tainted?(%{})
  end

  test "the built-in set is unchanged" do
    for name <- ~w(fetch_url web_search db_query delegate run_graph), do: assert(Runtime.outside_content?(name))
    refute Runtime.outside_content?("read_file")
  end
end

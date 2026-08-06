defmodule Pepe.Agent.CompactionSlotTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Compaction
  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Slots.Guard

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_compaction_slot_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp model, do: %Model{name: "m", base_url: "x", model: "id", context_window: 128_000}

  test "the builtin occupant claims the compaction slot" do
    assert Compaction.name() == "builtin"
    assert Compaction.slot() == "compaction"
  end

  test "compact/4 returns the messages unchanged when nothing needs condensing" do
    messages = [%{"role" => "user", "content" => "hi"}]
    assert {:ok, ^messages} = Compaction.compact(messages, model(), %Pepe.Config.Agent{name: "a"}, nil)
  end

  test "a plugin pinned to the compaction slot is called instead of the builtin", %{home: home} do
    write_compaction_plugin(home, "PepeCompactionSlotTest.Fake", "fake_compaction")
    Config.put_slot("compaction", "fake_compaction")

    messages = [%{"role" => "user", "content" => "hi"}]
    agent = %Pepe.Config.Agent{name: "a"}

    assert Guard.call("compaction", :compact, [messages, model(), agent, nil], agent) ==
             {:ok, [%{"role" => "system", "content" => "[fake] condensed"}]}
  end

  test "a crashing compaction plugin degrades to the builtin, not a broken turn", %{home: home} do
    write_compaction_plugin(home, "PepeCompactionSlotTest.Boom", "boom_compaction", crash?: true)
    Config.put_slot("compaction", "boom_compaction")

    messages = [%{"role" => "user", "content" => "hi"}]
    agent = %Pepe.Config.Agent{name: "a"}

    assert Guard.call("compaction", :compact, [messages, model(), agent, nil], agent) == {:ok, messages}
  end

  defp write_compaction_plugin(home, module, name, opts \\ []) do
    body =
      if opts[:crash?] do
        "def compact(_messages, _model, _agent, _session_key), do: raise(\"boom\")"
      else
        "def compact(_messages, _model, _agent, _session_key), do: {:ok, [%{\"role\" => \"system\", \"content\" => \"[fake] condensed\"}]}"
      end

    File.write!(Path.join([home, "plugins", "#{name}.exs"]), """
    defmodule #{module} do
      def name, do: "#{name}"
      def slot, do: "compaction"
      #{body}
    end
    """)
  end
end

defmodule Cortex.ToolsPluginTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "cortex_plugins_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "a drop-in .exs plugin becomes an available, executable tool", %{home: home} do
    plugin = """
    defmodule CortexPluginTest.Echo do
      @behaviour Cortex.Tools.Tool
      import Cortex.Tools.Tool, only: [function: 3]

      def name, do: "echo_test"

      def spec do
        function("echo_test", "Echo the text back.", %{
          "type" => "object",
          "properties" => %{"text" => %{"type" => "string"}},
          "required" => ["text"]
        })
      end

      def run(%{"text" => text}, _ctx), do: {:ok, "echo: " <> text}
    end
    """

    File.write!(Path.join([home, "plugins", "echo.exs"]), plugin)

    # registered alongside the built-ins
    assert "echo_test" in Cortex.Tools.names()
    assert Cortex.Tools.get("echo_test")
    assert Cortex.Tools.specs(["echo_test"]) != nil

    # and runs through the normal execute path
    call = %{"function" => %{"name" => "echo_test", "arguments" => ~s({"text":"hi"})}}
    assert Cortex.Tools.execute(call, %{}) == "echo: hi"
  end

  test "an agent can install a plugin via plugins/ and enable it on itself", %{home: home} do
    # the plugins/ path prefix lands in the global plugins dir
    path = Cortex.Agent.Workspace.resolve("plugins/echo2.exs", "zak")
    assert path == Path.join([home, "plugins", "echo2.exs"])

    File.write!(path, """
    defmodule CortexPluginTest.Echo2 do
      @behaviour Cortex.Tools.Tool
      import Cortex.Tools.Tool, only: [function: 3]
      def name, do: "echo2"
      def spec, do: function("echo2", "echo", %{"type" => "object", "properties" => %{}})
      def run(_args, _ctx), do: {:ok, "ok"}
    end
    """)

    assert "echo2" in Cortex.Tools.names()

    # the agent adds the new tool to its own allowlist
    Cortex.Config.put_agent(%Cortex.Config.Agent{name: "zak", system_prompt: "x", tools: []})
    assert {:ok, _} = Cortex.Tools.EnableTool.run(%{"name" => "echo2"}, %{agent: %{name: "zak"}})
    assert "echo2" in Cortex.Config.get_agent("zak").tools
  end

  test "a non-tool .exs is ignored", %{home: home} do
    File.write!(
      Path.join([home, "plugins", "junk.exs"]),
      "defmodule CortexPluginTest.Junk do end"
    )

    assert is_list(Cortex.Tools.names())
  end
end

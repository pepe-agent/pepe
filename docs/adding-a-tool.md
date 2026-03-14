# Adding a tool

A tool is any module implementing the `Pepe.Tools.Tool` behaviour
(`name/0`, `spec/0`, `run/2`). Two ways to ship one:

**Built-in** (compiled in) - add the module under `lib/pepe/tools/` and list it
in `@builtin` in `Pepe.Tools`:

```elixir
defmodule Pepe.Tools.MyTool do
  @behaviour Pepe.Tools.Tool
  import Pepe.Tools.Tool, only: [function: 3]

  def name, do: "my_tool"
  def spec, do: function("my_tool", "what it does", %{"type" => "object", "properties" => %{}})
  def run(_args, _ctx), do: {:ok, "result text"}
end
```

**Plugin** (drop-in, no recompile) - put the same module in a `.exs` under
`~/.pepe/plugins/`. It's compiled at runtime, hot-reloaded on change (by mtime),
and appears in `mix pepe tools`. Add its `name` to an agent's `tools` to enable
it:

```elixir
# ~/.pepe/plugins/weather.exs
defmodule PepePlugins.Weather do
  @behaviour Pepe.Tools.Tool
  import Pepe.Tools.Tool, only: [function: 3]

  def name, do: "weather"
  def spec, do: function("weather", "Get the weather for a city.",
    %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}}, "required" => ["city"]})
  def run(%{"city" => city}, _ctx), do: {:ok, "Sunny in #{city}"}
end
```

---

[Back to the docs index](../README.md#documentation)

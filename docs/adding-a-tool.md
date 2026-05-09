# Adding a tool

A tool is any module implementing the `Pepe.Tools.Tool` behaviour
(`name/0`, `spec/0`, `run/2`). Two ways to ship one:

**Built-in** (compiled in): add the module under `lib/pepe/tools/` and list it
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

**Plugin** (drop-in, no recompile): put the same module in a `.exs` under
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

## Running alongside the others

A model often asks for several tools in one turn. Pepe runs the ones that say they
can be run together at the same time, so three URL fetches cost one round trip
instead of three. A tool opts in with `concurrent?/0`:

```elixir
def concurrent?, do: true
```

It is `false` unless you say otherwise, and that is deliberate: the failure it
prevents is a silent one. Two edits to the same file, run at once, both read the
original and one of them quietly overwrites the other, with no error anywhere.
Sequential edits compose. So a tool waits its turn until somebody has actually
thought about whether it can race with the ones beside it.

Say `true` if your tool only reads, or only reaches out over the network. Leave it
alone if it writes, executes, or otherwise changes the machine. A serial tool is
also a barrier: everything the model asked for before it finishes first, and
everything after it starts only once it is done, so a read the model placed after
a write really does read what the write left behind.

---

[Back to the docs index](../README.md#documentation)

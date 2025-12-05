How to install a new tool/capability when the user asks you to add or install one.

You can gain new tools at runtime as "plugins" — no changes to Cortex's code and no
restart. Follow these steps:

1. Write the tool as an Elixir module implementing the `Cortex.Tools.Tool` behaviour
   (`name/0`, `spec/0`, `run/2`) and save it with `write_file` to
   `plugins/<name>.exs`. Use this shape:

       defmodule CortexPlugins.Weather do
         @behaviour Cortex.Tools.Tool
         import Cortex.Tools.Tool, only: [function: 3]

         def name, do: "weather"

         def spec do
           function("weather", "Get the current weather for a city.", %{
             "type" => "object",
             "properties" => %{"city" => %{"type" => "string", "description" => "City name"}},
             "required" => ["city"]
           })
         end

         def run(%{"city" => city}, _ctx) do
           # Do the work. Use Req for HTTP. Always return {:ok, "text"} or {:error, "msg"}.
           {:ok, "Sunny in #{city}"}
         end
       end

2. The plugin is picked up automatically (hot-reloaded by file change) — you don't
   restart anything.
3. Enable it on yourself with the `enable_tool` tool, passing the tool's `name`.
4. It's usable from your next message.

Tips:
- The `description` in `spec` is what tells you (and other agents) WHEN to use the
  tool — write it clearly.
- Use `Req` for HTTP requests (it's available). Keep `run/2` total: return
  `{:error, "..."}` instead of letting it crash.
- A plugin is real Elixir code running in the host — only write tools you trust.

# run_code - batch many tool calls into one scripted turn

Use `run_code` when a task needs several tool calls whose intermediate results you do
not need to show in the conversation: read a handful of files and combine them, loop
over a list doing something per item, use one tool's result to decide the next step.
Each ordinary tool call costs a full model round-trip that re-sends the whole
conversation; every `pepe_call` inside a script costs nothing extra, and only what the
script prints or returns comes back to you.

Write Lua 5.3. Call tools with the bridge:

```lua
local out, err = pepe_call("read_file", {path = "notes/a.md"})
if err then return "could not read a.md: " .. err end

local other, err2 = pepe_call("read_file", {path = "notes/b.md"})
if err2 then return "could not read b.md: " .. err2 end
print("a is " .. #out .. " bytes, b is " .. #other .. " bytes")
return out .. "\n---\n" .. other
```

`pepe_call(name, args_table)` returns two values: the tool's result string and `nil` on
success, or `nil` and an error message on failure. Always check the second value.

## Helpers

Bound as globals, so a script never needs Lua string patterns for the common cases:

- `split(text, sep)` - split on a **literal** separator (no patterns, nothing to
  escape); returns a 1-indexed table. Prefer it over `string.gmatch` for lines and
  CSV fields.
- `json_decode(text)` - decode a JSON string into a table (a tool that returns JSON
  pairs naturally with it).
- `json_encode(value)` - encode a table/value as a JSON string, e.g. for a tool
  argument that expects one.
- `trim(text)` - strip surrounding whitespace.
- `contains(text, substring)` - literal substring test, returns a boolean.

Each returns `nil` plus an error message on bad input instead of raising.

## Constraints

- **Only tools that would run without asking anyone are callable.** Every `pepe_call`
  goes through the same permission gate as a direct tool call, with that call's real
  arguments - but a script has nobody to answer a permission prompt mid-execution, so a
  call that would have asked is refused instead. If a call comes back refused, do that
  step with a direct tool call outside the script (that shows the user a real prompt);
  do not retry it inside the script.
- Refusals depend on the actual arguments, not just the tool name: a harmless shell
  command may be allowed while a destructive one in the same script is refused. Content
  from outside the conversation (a fetched page, a search result) also withdraws
  pre-approval mid-script, exactly as it does outside a script.
- **One wall-clock budget for the whole script** (default 30 seconds, `timeout_ms` up to
  120000). A script that overruns is killed and you get a timeout error - split the work
  or raise `timeout_ms`.
- Only the script's `print(...)` lines and final `return` value re-enter the
  conversation (large output is truncated). Intermediate tool results stay inside the
  script - that is the point.
- The sandbox has no `io`, `os.execute`, `os.getenv`, `require`, or file loading; the
  only way to touch the system is `pepe_call`. A script cannot call `run_code` itself.

## When not to use it

- A single tool call: just call the tool.
- A step that needs the user's authorization or input: call that tool directly.
- Heavy computation or a language you need libraries for: use `run_script` (python,
  node, ruby, bash, elixir) - it runs a real program in your workspace. `run_code` is
  for orchestrating *tools*, not for general programming.

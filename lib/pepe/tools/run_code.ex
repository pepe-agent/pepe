defmodule Pepe.Tools.RunCode do
  @moduledoc """
  Run a Lua script that calls the agent's other tools in-process - many tool steps,
  one model round-trip.

  Every tool-call round-trip re-sends the whole accumulated history to the model, so a
  task needing eight file reads costs eight model calls. A script calling those same
  eight tools through the `pepe_call` bridge costs one: only the script's printed/returned
  output re-enters the conversation, never each intermediate tool result.

  ## The security boundary

  A script is synchronous - there is no human available to answer a permission prompt
  mid-execution. So the rule is: a script may only call a tool if `Pepe.Permissions.gate/3`,
  invoked with that call's REAL name and args at the moment the script attempts it, returns
  a clean `:allow`. The bridge strips `:authorize`/`:ask_user` from the ctx it gates with,
  which makes the gate treat the script as an unattended surface: anything that would have
  asked a human is refused instead (a Lua-visible `nil, error` return, never an escalation
  to a prompt, never a fallback to running anyway). The gate is called fresh for every
  single call - never a static allowlist computed up front - so per-arg risk hints
  (`Pepe.Permissions.Risk`) and the untrusted-content taint apply exactly as they do to a
  direct tool call, including a taint the script itself picks up mid-run (a `fetch_url`
  early in the script withdraws `auto_approve` for the calls after it, via the same
  `Pepe.Agent.Runtime.taint_if_outside/1` the runtime's own loop uses).

  ## Isolation

  Luerl is a pure-BEAM Lua 5.3 interpreter: the sandbox only ever sees what this module
  explicitly binds into it, and a runaway script is stopped by two independent backstops,
  either of which fires on its own - a wall-clock `Task` timeout, and a hard
  `:max_heap_size` cap on the interpreter process for a script that allocates memory
  faster than any timeout could catch (a string-doubling loop reaches gigabytes in
  milliseconds; the heap cap kills just that process, immediately, before the node
  feels it). The stdlib pieces that reach outside the VM (`os.execute`, `os.getenv`,
  `os.remove`, `os.rename`, `os.tmpname`, `os.exit`, `io`, `dofile`, `loadfile`, `load`,
  `loadstring`, `require`, `package`) are removed before the script runs - the filesystem
  and the environment are reachable only through `pepe_call`, where the gate stands -
  and `string.dump`/`debug` are stripped as defense-in-depth on top.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Permissions
  alias Pepe.Tools

  @default_timeout_ms 30_000
  @max_timeout_ms 120_000
  # Same cap run_script puts on its own stdout - the generic spill in Tools.finalize
  # never triggers below 16KB, so this keeps script output conversation-sized itself.
  @max_output 10_000

  # Heap cap for the interpreter process, in words (~256MB at 8 bytes/word). Legitimate
  # scripts stay far below this: tool results arriving through the bridge are
  # conversation-sized (Tools.finalize spills anything over ~16KB to a file) and script
  # output is capped at @max_output, so even a script juggling hundreds of tool results
  # and building large intermediate strings sits in single-digit MB - this is two orders
  # of magnitude of headroom, while a memory bomb racing toward host-threatening
  # gigabytes still dies within milliseconds. `include_shared_binaries: true` in
  # max_heap_flag/0 is load-bearing: Lua strings are Erlang binaries, and binaries over
  # 64 bytes live OFF the process heap - without it, a string-doubling bomb reaches 1GB+
  # without ever tripping the cap (verified empirically on OTP 28).
  @max_heap_words 32_000_000

  @print_buf :pepe_run_code_print
  @tool_call_count :pepe_run_code_tool_calls

  # The largest integer a float carries exactly (2^53): an integral float inside this
  # range prints as a plain integer, one outside it keeps float notation - trunc/1
  # would be inventing digits the float never had.
  @max_exact_float 9_007_199_254_740_992

  # Known Lua-runtime mistake classes, mapped to actionable hints - checked in order,
  # first match wins, no match leaves the raw error alone. The same move as
  # hermes-agent's `_sandbox_failure_hint`, rebuilt for the error text Luerl actually
  # produces (verified by triggering each one - Luerl's wording differs from stock
  # Lua 5.3: "invalid index in nil", "undefined function nil", "bad argument ... to '..'").
  # Adding a class later is one more {regex, hint} line here.
  @lua_hints [
    {~r/bad argument .* to '(gmatch|gsub|match|find)'/,
     "string.gmatch/gsub/match/find take the subject string FIRST and the pattern " <>
       "second - string.gmatch(subject, pattern), not the reverse. For splitting on a " <>
       "literal separator, split(text, sep) is usually a better fit than a Lua pattern"},
    {~r/bad argument .* to 'format'/,
     "a %d format spec needs an integer - use math.floor(x) or switch to %s or %.2f; " <>
       "the other common cause is a mismatch between the number of % specifiers and " <>
       "the number of arguments"},
    {~r/invalid index in nil/,
     "pepe_call returns (result, err) - check err before indexing result; tables from " <>
       "split/json_decode are 1-indexed, not 0-indexed; and sandbox-removed globals " <>
       "like io are nil here"},
    {~r/bad argument .* to '\.\.'/,
     "nil cannot be concatenated - nil is not false or \"\", so guard with (x or \"\") " <>
       "before concatenating"},
    {~r/undefined function/,
     "require, io, os.execute/os.getenv, load, loadstring, dofile and loadfile do not " <>
       "exist in this sandbox - reach the filesystem and network only through pepe_call"}
  ]

  # Globals removed from the sandbox before the script runs. Everything here either
  # reaches outside the VM (shell, env, filesystem) or loads code from disk - except the
  # last two: Luerl 1.5 implements neither the dangerous `debug` introspection functions
  # nor any loader that could swallow `string.dump` bytecode (load/loadstring/dofile/
  # loadfile are already gone), so stripping them changes nothing today. They go anyway,
  # so a future Luerl release implementing more of `debug` doesn't silently open a hole.
  @disabled_globals [
    ["os", "execute"],
    ["os", "getenv"],
    ["os", "remove"],
    ["os", "rename"],
    ["os", "tmpname"],
    ["os", "exit"],
    ["io"],
    ["dofile"],
    ["loadfile"],
    ["load"],
    ["loadstring"],
    ["require"],
    ["package"],
    ["string", "dump"],
    ["debug"]
  ]

  # Under review mode the runtime stages these instead of running them - a staging step
  # the bridge cannot reproduce mid-script, so they must go through the direct path.
  @stageable ~w(write_file edit_file move_file)

  @impl true
  def name, do: "run_code"

  @impl true
  def spec do
    function(
      "run_code",
      "Run a Lua 5.3 script that can call your other tools via pepe_call(name, args_table), " <>
        "batching many tool steps into ONE turn. Use it when a task needs several tool calls whose " <>
        "intermediate results you don't need to see in the conversation: read several files and combine " <>
        "them, loop over a list doing something per item, branch on one tool's result to pick the next " <>
        "step. Only what the script print()s or returns comes back to you - intermediate tool results " <>
        "stay inside the script, costing no extra round-trips. pepe_call returns (result, nil) on " <>
        "success or (nil, error) on failure; only tools that would run without asking anyone are " <>
        "callable here, so if a call is refused, fall back to calling that tool directly the normal " <>
        "way. The whole script shares one wall-clock budget (default 30s) and a fixed memory budget - " <>
        "for big data sets, process less at once.",
      %{
        "type" => "object",
        "properties" => %{
          "script" => %{
            "type" => "string",
            "description" =>
              "Lua 5.3 source. Call tools with `local out, err = pepe_call(\"tool_name\", {arg=value})`; " <>
                "always check `err`. Use `split(text, sep)` to split on a literal separator (returns a " <>
                "1-indexed table) instead of Lua string patterns/gmatch - prefer it for splitting lines " <>
                "or CSV fields, e.g.: `local lines = split(csv_text, \"\\n\") for i = 2, #lines do local " <>
                "cols = split(lines[i], \",\") end` (row 1 is the header). More helpers: " <>
                "`json_decode(text)` decodes a JSON string into a table, `json_encode(value)` encodes a " <>
                "value as a JSON string, `trim(text)` strips surrounding whitespace, " <>
                "`contains(text, substring)` is a literal substring test (no patterns); each returns " <>
                "(nil, error) on bad input. Use print(...) and/or a final " <>
                "return for the output you want back."
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Wall-clock budget for the whole script in ms (default 30000, max 120000)."
          }
        },
        "required" => ["script"]
      }
    )
  end

  @impl true
  def run(%{"script" => script} = args, ctx) when is_binary(script) do
    timeout = timeout_ms(args)

    # Carry the run's permission state into the sandbox task: the gate reads the taint and
    # `:this_run` grants from the process dictionary, and the task's own dictionary starts
    # empty - without this, a tainted run's script would start conveniently untainted.
    # `tainted?(ctx)` (not `snapshot/0`) so a `:tainted` captured into ctx by the runtime's
    # batch fan-out wins over this process's dictionary, exactly as it does at the gate.
    perms = {Permissions.tainted?(ctx), Permissions.run_grants()}
    hooks_map = Pepe.Hooks.current_map()

    # Inside the sandbox the gate must read the LIVE taint (a fetch_url mid-script taints
    # the calls after it), so the captured `:tainted` must not ride along and mask it. And
    # there is no human mid-script: no `:authorize` means the gate refuses instead of
    # asking, which is the entire security contract of this tool. `:no_pending_approval`
    # keeps that refusal a plain refusal - a script-internal block must never park a
    # pending approval (there is no way to resume a half-run Lua script later; the model
    # is told to retry the blocked tool directly instead, and it is THAT direct call, if
    # itself unattended, that may park one).
    ctx = ctx |> Map.delete(:tainted) |> Map.drop([:authorize, :ask_user]) |> Map.put(:no_pending_approval, true)

    task =
      Task.async(fn ->
        # The interpreter runs one process further down, not here: the heap cap kills the
        # process that crosses it with reason :killed, and this task is LINKED to the
        # caller (Task.async), so carrying the flag itself would take the whole turn down
        # with the script. Instead this task traps exits and translates its linked
        # child's death into a value the caller can pattern match.
        Process.flag(:trap_exit, true)
        child = spawn_link(fn -> sandbox_main(script, ctx, perms, hooks_map) end)

        receive do
          {:EXIT, ^child, {:done, _payload} = done} ->
            done

          {:EXIT, ^child, :killed} ->
            # The only thing that kills the child is its own :max_heap_size flag - the
            # wall-clock path brutal-kills this task first, so it never reports at all.
            :out_of_memory

          {:EXIT, ^child, reason} ->
            {:crashed, reason}

          {:EXIT, _caller, reason} ->
            # The caller died mid-script (its own crash, not our timeout - that arrives
            # as an untrappable :brutal_kill). Don't leave the interpreter running
            # unwatched with no one left to enforce the wall clock.
            Process.exit(child, :kill)
            exit(reason)
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:done, {result, perms_after, map_after}}} ->
        Permissions.restore(perms_after)
        Pepe.Hooks.add_entries(map_after -- hooks_map)
        result

      {:ok, :out_of_memory} ->
        # Killed mid-flight: no way to know whether it had already ingested outside
        # content (a fetch_url before the runaway loop), so the run is conservatively
        # tainted - same reasoning as the timeout below.
        Permissions.taint()

        {:error,
         "script ran out of memory (each script gets a fixed heap budget) - " <>
           "process less data at once, e.g. page through it or filter it inside the tool call"}

      {:ok, {:crashed, reason}} ->
        Permissions.taint()
        {:error, "script crashed: #{inspect(reason)}"}

      nil ->
        # Killed mid-flight: no way to know whether it had already ingested outside content
        # (a fetch_url before the runaway loop), so the run is conservatively tainted.
        Permissions.taint()
        {:error, "script timed out after #{timeout}ms (the whole script shares one wall-clock budget)"}
    end
  end

  def run(%{"script" => _}, _ctx), do: {:error, "'script' must be a string"}

  # `code` is what several other tools/projects call this parameter - a mix-up worth
  # absorbing rather than failing the whole call over the argument's name.
  def run(%{"code" => code} = args, ctx) when is_binary(code) do
    args |> Map.delete("code") |> Map.put("script", code) |> run(ctx)
  end

  def run(_, _), do: {:error, "missing 'script'"}

  defp timeout_ms(%{"timeout_ms" => t}) when is_integer(t) and t > 0, do: min(t, @max_timeout_ms)
  defp timeout_ms(_), do: @default_timeout_ms

  # The whole interpreter runs here, under the heap cap - the second backstop next to
  # the wall-clock timeout, for the script that allocates memory far faster than any
  # timeout could catch. Crossing @max_heap_words makes the BEAM kill THIS process only,
  # immediately; the trapping task above turns that into :out_of_memory.
  defp sandbox_main(script, ctx, perms, hooks_map) do
    Process.flag(:max_heap_size, %{
      size: @max_heap_words,
      kill: true,
      error_logger: false,
      include_shared_binaries: true
    })

    Permissions.restore(perms)
    Pepe.Hooks.start_map(hooks_map)
    result = execute(script, ctx)
    # Hand the end-state back: a taint picked up inside the script must outlive it, and
    # redaction-map entries grown here must reach the turn's closing restore.
    exit({:done, {result, Permissions.snapshot(), Pepe.Hooks.current_map()}})
  end

  # Runs inside the sandbox task. Everything is caught here: the task is linked to the
  # turn, so an escaped raise/throw would take the whole turn down with it.
  defp execute(script, ctx) do
    Process.put(@print_buf, [])
    Process.put(@tool_call_count, 0)

    case :luerl.do_dec(script, sandbox_state(ctx)) do
      {:ok, results, _st} -> {:ok, render_output(results)}
      {:lua_error, err, _st} -> {:error, lua_error_message(err) <> retry_note()}
      {:error, errors, _warnings} -> {:error, "Lua syntax error: #{format_issues(errors)}"}
    end
  rescue
    e -> {:error, "script crashed: #{Exception.message(e)}" <> retry_note()}
  catch
    kind, reason -> {:error, "script crashed: #{inspect({kind, reason})}" <> retry_note()}
  end

  # The hint (when a known mistake class matches) leads, the raw error stays - guidance
  # the model can act on first, the exact failure right behind it.
  defp lua_error_message(err) do
    raw = format_lua_error(err)

    case Enum.find(@lua_hints, fn {regex, _hint} -> Regex.match?(regex, raw) end) do
      {_regex, hint} -> "Lua error (hint: #{hint}): #{raw}"
      nil -> "Lua error: #{raw}"
    end
  end

  # A script can fail halfway through work that already happened: tell the model, so a
  # retry doesn't blindly repeat calls with side effects. Silent when nothing ran.
  defp retry_note do
    case Process.get(@tool_call_count, 0) do
      0 ->
        ""

      n ->
        "\n#{n} tool call(s) already ran in this script before it failed - if you retry, " <>
          "don't blindly repeat calls that may have side effects (writes, sends, etc.); " <>
          "consider what's already been done."
    end
  end

  defp sandbox_state(ctx) do
    state = :luerl.init()
    state = set_global(state, ["pepe_call"], bridge_fun(ctx))
    state = set_global(state, ["print"], print_fun())
    state = set_global(state, ["split"], split_fun())
    state = set_global(state, ["json_decode"], json_decode_fun())
    state = set_global(state, ["json_encode"], json_encode_fun())
    state = set_global(state, ["trim"], trim_fun())
    state = set_global(state, ["contains"], contains_fun())
    Enum.reduce(@disabled_globals, state, &set_global(&2, &1, nil))
  end

  defp set_global(state, keys, value) do
    {:ok, state} = :luerl.set_table_keys_dec(keys, value, state)
    state
  end

  ###
  ### the tool bridge - pepe_call(name, args)
  ###

  defp bridge_fun(ctx) do
    fn args, lua_state ->
      outcome =
        with {:ok, name, tool_args} <- decode_call(args, lua_state) do
          bridge_call(name, tool_args, ctx)
        end

      case outcome do
        {:ok, result} -> {[result], lua_state}
        {:error, message} -> {[nil, message], lua_state}
      end
    end
  end

  defp decode_call([name | rest], lua_state) when is_binary(name) do
    case decode_tool_args(List.first(rest), lua_state) do
      {:ok, map} -> {:ok, name, map}
      {:error, _} = error -> error
    end
  end

  defp decode_call(_args, _lua_state), do: {:error, "pepe_call: first argument must be a tool name string"}

  defp decode_tool_args(nil, _lua_state), do: {:ok, %{}}

  defp decode_tool_args(json, _lua_state) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, "pepe_call: string args must be a JSON object"}
    end
  end

  defp decode_tool_args(other, lua_state) do
    case lua_value(:luerl.decode(other, lua_state)) do
      map when is_map(map) -> {:ok, map}
      _ -> {:error, "pepe_call: args must be a table of named arguments, e.g. {path=\"notes.md\"}"}
    end
  rescue
    _ -> {:error, "pepe_call: could not decode args"}
  end

  defp bridge_call("run_code", _args, _ctx),
    do: {:error, "run_code cannot call itself from inside a script"}

  defp bridge_call(name, _args, %{review: true}) when name in @stageable do
    {:error, "under review mode, #{name} must be staged for approval - call it directly, outside the script"}
  end

  defp bridge_call(name, args, ctx) do
    # A name no tool anywhere answers to is a typo, not a permission question - catch it
    # before the gate and suggest the closest real name(s), so the model can correct the
    # spelling instead of concluding the tool is forbidden.
    if Tools.get(name) == nil and not Pepe.MCP.mcp_tool?(name) do
      {:error, unknown_tool_error(name, ctx)}
    else
      gated_call(name, args, ctx)
    end
  end

  defp gated_call(name, args, ctx) do
    # The REAL gate, with this call's real name and args, at the moment the script attempts
    # it - the same call `Pepe.Agent.Runtime.gate_tool/6` makes for a direct tool call. The
    # ctx carries no `:authorize` (stripped in run/2), so anything short of a clean `:allow`
    # comes back as a denial here: refused inside the sandbox, never escalated to a human,
    # never run anyway.
    case Permissions.gate(name, args, ctx) do
      :allow ->
        call = %{"function" => %{"name" => name, "arguments" => args}}
        # execute/2 = run_only + finalize, so redaction, secret scrubbing and spilling
        # apply to a script-called tool's result exactly as they do outside the sandbox.
        result = Tools.execute(call, ctx)
        Pepe.Agent.Runtime.taint_if_outside(name)

        if Tools.error?(result) do
          {:error, result}
        else
          # Feeds the retry-safety note: a later script-ending error tells the model
          # how many calls with possible side effects already ran.
          Process.put(@tool_call_count, Process.get(@tool_call_count, 0) + 1)
          {:ok, result}
        end

      :deny ->
        {:error, Permissions.denied_message(name)}

      {:deny, reason} ->
        {:error, Permissions.denied_message(name, reason)}
    end
  end

  defp unknown_tool_error(name, ctx) do
    base = "pepe_call: unknown tool '#{name}'"

    case closest_tool_names(name, ctx) do
      [] -> base
      [suggestion] -> base <> ". Did you mean '#{suggestion}'?"
      suggestions -> base <> ". Did you mean one of: #{Enum.map_join(suggestions, ", ", &"'#{&1}'")}?"
    end
  end

  # Closest real names by Jaro distance, against the agent's own tool list when there is
  # one (those are the names it can actually call) - 0.8 keeps a swapped-letters typo
  # ("raed_file" ~ 0.96) and drops names that merely rhyme.
  defp closest_tool_names(name, ctx) do
    candidate_tool_names(ctx)
    |> Enum.map(&{&1, String.jaro_distance(name, &1)})
    |> Enum.filter(fn {_candidate, distance} -> distance >= 0.8 end)
    |> Enum.sort_by(fn {_candidate, distance} -> -distance end)
    |> Enum.take(2)
    |> Enum.map(fn {candidate, _distance} -> candidate end)
  end

  defp candidate_tool_names(%{agent: %Pepe.Config.Agent{tools: tools}}) when is_list(tools) and tools != [],
    do: tools

  defp candidate_tool_names(_ctx), do: Tools.names()

  ###
  ### output - captured print() lines plus the script's return values
  ###

  defp print_fun do
    fn args, lua_state ->
      line = Enum.map_join(args, "\t", &lua_display(&1, lua_state))
      Process.put(@print_buf, [Process.get(@print_buf, []), line, "\n"])
      {[], lua_state}
    end
  end

  # A literal (never pattern) string split, bound as a global so a script doesn't have
  # to reach for Lua's string.gmatch/pattern matching for the single most common thing
  # a data-processing script does - splitting a CSV line or a block of text into lines.
  # Lua patterns have their own magic characters (%, ., +, ...) and gmatch's
  # subject-then-pattern argument order is an easy, silent mistake (observed live: a
  # model swapped them and got a cryptic "bad argument to gmatch" twice in a row before
  # giving up on the script entirely). `split` takes plain strings only - no patterns,
  # nothing to escape, nothing to get backwards.
  defp split_fun do
    fn
      [text, sep], lua_state when is_binary(text) and is_binary(sep) and sep != "" ->
        {encoded, lua_state} = :luerl.encode(String.split(text, sep), lua_state)
        {[encoded], lua_state}

      _args, lua_state ->
        {[nil, "split(text, sep): both arguments must be non-empty strings"], lua_state}
    end
  end

  # The remaining helper globals, same contract as split: bad input is a Lua-visible
  # (nil, message) return, never a crash out of the interpreter.

  defp json_decode_fun do
    fn
      [text | _], lua_state when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, value} ->
            {encoded, lua_state} = :luerl.encode(value, lua_state)
            {[encoded], lua_state}

          {:error, _} ->
            {[nil, "json_decode(text): not valid JSON"], lua_state}
        end

      _args, lua_state ->
        {[nil, "json_decode(text): argument must be a JSON string"], lua_state}
    end
  end

  defp json_encode_fun do
    fn
      [value | _], lua_state ->
        try do
          decoded = value |> :luerl.decode(lua_state) |> lua_value()

          case Jason.encode(decoded) do
            {:ok, json} -> {[json], lua_state}
            {:error, _} -> {[nil, "json_encode(value): value cannot be represented as JSON"], lua_state}
          end
        rescue
          # A value with no Elixir shape (a Lua function, e.g.) must be a Lua-visible
          # error, not an interpreter crash.
          _ -> {[nil, "json_encode(value): value cannot be represented as JSON"], lua_state}
        end

      [], lua_state ->
        {[nil, "json_encode(value): missing argument"], lua_state}
    end
  end

  defp trim_fun do
    fn
      [text | _], lua_state when is_binary(text) -> {[String.trim(text)], lua_state}
      _args, lua_state -> {[nil, "trim(text): argument must be a string"], lua_state}
    end
  end

  defp contains_fun do
    fn
      [text, sub | _], lua_state when is_binary(text) and is_binary(sub) ->
        {[String.contains?(text, sub)], lua_state}

      _args, lua_state ->
        {[nil, "contains(text, substring): both arguments must be strings"], lua_state}
    end
  end

  defp render_output(results) do
    printed = Process.get(@print_buf, []) |> IO.iodata_to_binary()
    returned = results |> Enum.reject(&is_nil/1) |> Enum.map_join("\n", &format_value/1)
    output = String.trim_trailing(printed <> returned)

    case output do
      "" -> "(script finished with no output - print(...) or return a value to send something back)"
      _ -> truncate(output)
    end
  end

  defp truncate(output) when byte_size(output) > @max_output,
    do:
      safe_truncate(output, @max_output) <>
        "\n... (output truncated at #{@max_output} bytes - filter or aggregate inside the " <>
        "script and print a summary instead of dumping raw data)"

  defp truncate(output), do: output

  # Clip to at most `max_bytes` without splitting a multi-byte UTF-8 codepoint: a raw
  # byte slice can cut one in half and hand the model invalid UTF-8 (same pattern as
  # Pepe.Tools.ReadFile's safe_truncate/2). A codepoint is at most 4 bytes, so backing
  # off up to 3 finds the boundary; output that was never valid UTF-8 to begin with
  # (Lua strings are raw bytes) keeps the plain byte slice - no back-off could repair it.
  defp safe_truncate(binary, max_bytes) do
    sizes = max_bytes..max(max_bytes - 3, 0)//-1

    case Enum.find(sizes, &String.valid?(binary_part(binary, 0, &1))) do
      nil -> binary_part(binary, 0, max_bytes)
      size -> binary_part(binary, 0, size)
    end
  end

  # Decoded (do_dec) return values: scalars as text, tables as JSON.
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_number(value), do: format_number(value)
  defp format_value(value) when is_boolean(value), do: to_string(value)

  defp format_value(value) when is_list(value) do
    case Jason.encode(lua_value(value)) do
      {:ok, json} -> json
      _ -> inspect(value)
    end
  end

  defp format_value(value), do: inspect(value)

  # Internal-form values reaching print(): strings/numbers are already plain, a table
  # reference needs decoding first.
  defp lua_display(value, _lua_state) when is_binary(value), do: value
  defp lua_display(value, _lua_state) when is_number(value), do: format_number(value)
  defp lua_display(true, _lua_state), do: "true"
  defp lua_display(false, _lua_state), do: "false"
  defp lua_display(nil, _lua_state), do: "nil"

  defp lua_display(other, lua_state) do
    format_value(:luerl.decode(other, lua_state))
  rescue
    _ -> "(unprintable)"
  end

  # Luerl decodes a Lua table to a {key, value} proplist. A table keyed 1..n is a Lua
  # array and becomes a list; anything else becomes a map, the JSON-object shape tool
  # args expect. An empty table is ambiguous and becomes the empty map for the same reason.
  defp lua_value(list) when is_list(list) do
    if lua_array?(list) do
      list |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {_k, v} -> lua_value(v) end)
    else
      Map.new(list, fn {k, v} -> {lua_key(k), lua_value(v)} end)
    end
  end

  defp lua_value(other), do: integralize(other)

  # Lua 5.3 arithmetic quietly promotes to float (one division, one float literal), and
  # a float sum then reaches the model as "1.52e4" or "46250.0" instead of "15200" -
  # seen live, and the model read it as a different number. A float carrying an exact
  # integer becomes that integer everywhere a Lua number turns into text or JSON; a
  # genuinely fractional float (4.29) stays a float.
  defp integralize(value) when is_float(value) do
    truncated = trunc(value)
    if truncated == value and abs(truncated) <= @max_exact_float, do: truncated, else: value
  end

  defp integralize(value), do: value

  defp format_number(value) do
    case integralize(value) do
      int when is_integer(int) -> Integer.to_string(int)
      float -> Float.to_string(float)
    end
  end

  defp lua_array?([]), do: false

  defp lua_array?(list) do
    keys = Enum.map(list, &elem(&1, 0))
    Enum.all?(keys, &is_integer/1) and Enum.sort(keys) == Enum.to_list(1..length(keys))
  end

  defp lua_key(key) when is_binary(key), do: key
  defp lua_key(key) when is_integer(key), do: Integer.to_string(key)
  defp lua_key(key), do: inspect(key)

  defp format_lua_error(err) do
    :luerl_lib.format_error(err) |> IO.chardata_to_string()
  rescue
    _ -> inspect(err)
  end

  defp format_issues(errors) when is_list(errors), do: Enum.map_join(errors, "; ", &format_issue/1)
  defp format_issues(other), do: inspect(other)

  defp format_issue({line, module, error}) do
    "line #{line}: #{module.format_error(error) |> IO.chardata_to_string()}"
  rescue
    _ -> inspect({line, error})
  end

  defp format_issue(other), do: inspect(other)
end

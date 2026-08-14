defmodule Pepe.Tools.RunCodeTest do
  # async: false - the permission taint and `:this_run` grants live in the test
  # process's dictionary, and PEPE_HOME is process-global.
  use ExUnit.Case, async: false

  alias Pepe.Config.Agent
  alias Pepe.Permissions
  alias Pepe.Tools.RunCode

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_run_code_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    # Each test runs in its own fresh process, so taint/run-grants can't leak between
    # tests - but be explicit anyway, mirroring PermissionsTest.
    Permissions.untaint()
    Permissions.clear_run_grants()

    {:ok, home: home}
  end

  defp tmp_path(home, name), do: Path.join(home, name)

  defp write_tmp!(home, name, content) do
    path = tmp_path(home, name)
    File.write!(path, content)
    path
  end

  ###
  ### plain scripting (no tools)
  ###

  test "a pure-computation script returns its result" do
    script = "local s = 0 for i = 1, 10 do s = s + i end return s"
    assert {:ok, "55"} = RunCode.run(%{"script" => script}, %{})
  end

  test "split(text, sep) splits on a literal separator, no Lua patterns involved" do
    script = ~s"""
    local rows = split("a,b,c\\nd,e,f", "\\n")
    local cols = split(rows[2], ",")
    return #rows, #cols, cols[1], cols[3]
    """

    assert {:ok, "2\n3\nd\nf"} = RunCode.run(%{"script" => script}, %{})
  end

  test "split refuses non-string or empty-separator arguments instead of crashing" do
    assert {:ok, out} = RunCode.run(%{"script" => "return select(2, split(\"a,b\", \"\"))"}, %{})
    assert out =~ "must be non-empty strings"
  end

  test "print output is captured and combined with the return value" do
    assert {:ok, "a\t1\nb"} = RunCode.run(%{"script" => ~s[print("a", 1) return "b"]}, %{})
  end

  test "a returned table comes back as JSON" do
    assert {:ok, out} = RunCode.run(%{"script" => ~s(return {a = 1, b = {"x", "y"}})}, %{})
    assert Jason.decode!(out) == %{"a" => 1, "b" => ["x", "y"]}
  end

  test "truncating oversized output never splits a UTF-8 codepoint" do
    # 1 ASCII byte + 6000 two-byte codepoints (0xC3 0xA9 = "é") = 12001 bytes: every
    # codepoint starts at an odd offset, so a raw binary_part at the 10_000-byte cap
    # lands mid-codepoint and hands the model invalid UTF-8. The clip must back off
    # to the boundary instead.
    script = ~s[return "a" .. string.rep(string.char(195, 169), 6000)]

    assert {:ok, out} = RunCode.run(%{"script" => script}, %{})
    assert String.valid?(out)
    assert out =~ "output truncated at 10000 bytes"
    refute out =~ <<0xC3, 0x0A>>
  end

  test "output that was never valid UTF-8 still comes back clipped, not eaten" do
    # Lua strings are raw bytes: a script can emit invalid UTF-8 on purpose. The
    # boundary back-off cannot repair that, so it must keep the plain byte slice
    # (pre-existing behavior) rather than backing off further or crashing.
    script = ~s[return string.rep(string.char(255), 10050)]

    assert {:ok, out} = RunCode.run(%{"script" => script}, %{})
    assert out =~ "output truncated at 10000 bytes"
    assert binary_part(out, 0, 10_000) == :binary.copy(<<255>>, 10_000)
  end

  test "the truncation notice tells the model to aggregate inside the script, not just that it was cut" do
    assert {:ok, out} = RunCode.run(%{"script" => ~s[return string.rep("x", 20000)]}, %{})
    assert out =~ "filter or aggregate inside the script"
  end

  test "a 'code' argument is accepted as an alias for 'script'" do
    assert {:ok, "2"} = RunCode.run(%{"code" => "return 1 + 1"}, %{})
  end

  ###
  ### number rendering - a float carrying an exact integer must read as one
  ###

  test "an integral float sum comes back as a plain integer, not 1.52e4 or 15200.0" do
    script = "local s = 0 for i = 1, 4 do s = s + 3800.0 end return s"
    assert {:ok, "15200"} = RunCode.run(%{"script" => script}, %{})
  end

  test "a genuinely fractional float keeps its fraction" do
    assert {:ok, "4.29"} = RunCode.run(%{"script" => "return 4.29"}, %{})
  end

  test "print() renders integral floats as integers too" do
    assert {:ok, "46250\t1.5"} = RunCode.run(%{"script" => "print(46250.0, 1.5)"}, %{})
  end

  test "integral floats inside a returned table become JSON integers" do
    assert {:ok, out} = RunCode.run(%{"script" => "return {total = 15200.0, avg = 4.29}"}, %{})
    assert Jason.decode!(out) == %{"total" => 15_200, "avg" => 4.29}
    refute out =~ "e4"
  end

  ###
  ### helper globals - json_decode/json_encode/trim/contains
  ###

  test "json_decode turns a JSON string into a 1-indexed Lua table" do
    script = "local t = json_decode('{\"a\": [10, 20, 30]}') return t.a[2]"
    assert {:ok, "20"} = RunCode.run(%{"script" => script}, %{})
  end

  test "json_decode refuses malformed JSON and non-string input instead of crashing" do
    assert {:ok, out} = RunCode.run(%{"script" => ~s[return select(2, json_decode("{nope"))]}, %{})
    assert out =~ "not valid JSON"

    assert {:ok, out} = RunCode.run(%{"script" => "return select(2, json_decode(5))"}, %{})
    assert out =~ "must be a JSON string"
  end

  test "json_encode turns a Lua table into a JSON string" do
    assert {:ok, out} = RunCode.run(%{"script" => ~s[return json_encode({a = 1, b = {"x", "y"}})]}, %{})
    assert Jason.decode!(out) == %{"a" => 1, "b" => ["x", "y"]}
  end

  test "json_encode refuses what JSON cannot carry instead of crashing" do
    assert {:ok, out} = RunCode.run(%{"script" => "return select(2, json_encode(print))"}, %{})
    assert out =~ "cannot be represented as JSON"
  end

  test "trim strips surrounding whitespace and refuses non-strings" do
    assert {:ok, "hi"} = RunCode.run(%{"script" => ~s[return trim("  hi\\n")]}, %{})

    assert {:ok, out} = RunCode.run(%{"script" => "return select(2, trim(5))"}, %{})
    assert out =~ "must be a string"
  end

  test "contains is a literal substring test and refuses non-strings" do
    script = ~s[return contains("hello world", "lo w"), contains("hello", "zz")]
    assert {:ok, "true\nfalse"} = RunCode.run(%{"script" => script}, %{})

    assert {:ok, out} = RunCode.run(%{"script" => "return select(2, contains(1, 2))"}, %{})
    assert out =~ "must be strings"
  end

  ###
  ### Lua failure hints - known mistake classes get guidance appended to the raw error
  ###

  test "a bad gmatch call hints at the subject-first argument order" do
    script = ~s[for w in string.gmatch(nil, "%a+") do print(w) end]
    assert {:error, message} = RunCode.run(%{"script" => script}, %{})
    assert message =~ "subject string FIRST"
    assert message =~ "gmatch"
  end

  test "a bad string.format call hints at math.floor and specifier/argument mismatch" do
    assert {:error, message} = RunCode.run(%{"script" => ~s[return string.format("%d", "abc")]}, %{})
    assert message =~ "math.floor"
    assert message =~ "format"
  end

  test "indexing nil hints at checking err and 1-indexing" do
    assert {:error, message} = RunCode.run(%{"script" => "local t = nil return t.x"}, %{})
    assert message =~ "check err before indexing result"
    assert message =~ "invalid index in nil"
  end

  test "concatenating nil hints at the (x or \"\") guard" do
    assert {:error, message} = RunCode.run(%{"script" => ~s[return "a" .. nil]}, %{})
    assert message =~ ~s[(x or "")]
  end

  test "calling a sandbox-removed function hints at pepe_call instead" do
    assert {:error, message} = RunCode.run(%{"script" => ~s[return require("os")]}, %{})
    assert message =~ "do not exist in this sandbox"
    assert message =~ "pepe_call"
  end

  test "an error matching no known class stays a plain raw error, no hint" do
    assert {:error, message} = RunCode.run(%{"script" => ~s[error("totally novel failure")]}, %{})
    assert message =~ "totally novel failure"
    refute message =~ "hint:"
  end

  test "a script with no output says so instead of returning nothing" do
    assert {:ok, out} = RunCode.run(%{"script" => "local x = 1 + 1"}, %{})
    assert out =~ "no output"
  end

  test "a syntactically invalid script is a readable error, not a crash" do
    assert {:error, message} = RunCode.run(%{"script" => "this is not lua ("}, %{})
    assert message =~ "Lua syntax error"
  end

  test "a runtime Lua error is a readable error, not a crash" do
    assert {:error, message} = RunCode.run(%{"script" => ~s[error("boom")]}, %{})
    assert message =~ "Lua error"
    assert message =~ "boom"
  end

  test "an infinite loop is killed by the wall-clock timeout" do
    assert {:error, message} = RunCode.run(%{"script" => "while true do end", "timeout_ms" => 200}, %{})
    assert message =~ "timed out after 200ms"
  end

  test "the escape hatches are stripped from the sandbox" do
    script =
      "return type(os.execute), type(os.getenv), type(io), type(dofile), type(loadfile), " <>
        "type(package), type(string.dump), type(debug)"

    assert {:ok, "nil\nnil\nnil\nnil\nnil\nnil\nnil\nnil"} = RunCode.run(%{"script" => script}, %{})
  end

  test "a memory-bomb script is killed by the heap cap, fast, with a clear error" do
    # Doubles a string toward gigabytes within milliseconds - the wall-clock timeout
    # (set deliberately high here) could never catch it in time; the :max_heap_size cap
    # on the interpreter process must, killing only that process, well before 60s.
    script = ~s[local s = "x" while true do s = s .. s end]

    {elapsed_us, result} =
      :timer.tc(fn -> RunCode.run(%{"script" => script, "timeout_ms" => 60_000}, %{}) end)

    elapsed_ms = div(elapsed_us, 1000)
    assert {:error, message} = result
    assert message =~ "ran out of memory"

    assert elapsed_ms < 5_000,
           "heap kill took #{elapsed_ms}ms - did it fall through to the wall-clock timeout?"

    assert Permissions.tainted?(%{}),
           "an OOM-killed run must be conservatively tainted, same as a timed-out one"
  end

  ###
  ### the tool bridge
  ###

  test "a script calls an allowed tool and returns something derived from its result", %{home: home} do
    path = write_tmp!(home, "greeting.txt", "hello")
    agent = %Agent{name: "coder", auto_approve: ["read_file:reads_outside"]}

    script = """
    local out, err = pepe_call("read_file", {path = "#{path}"})
    if err then return "failed: " .. err end
    return "got: " .. out .. "!"
    """

    assert {:ok, "got: hello!"} = RunCode.run(%{"script" => script}, %{agent: agent})
  end

  test "a script chains several tools, branching on one result to decide the next", %{home: home} do
    write_tmp!(home, "pointer.txt", "use-b")
    write_tmp!(home, "a.txt", "contents of A")
    write_tmp!(home, "b.txt", "contents of B")
    agent = %Agent{name: "coder", auto_approve: ["read_file:reads_outside"]}

    script = """
    local pointer, err = pepe_call("read_file", {path = "#{tmp_path(home, "pointer.txt")}"})
    if err then return "failed: " .. err end
    local next_file = "#{tmp_path(home, "a.txt")}"
    if string.find(pointer, "use%-b") then next_file = "#{tmp_path(home, "b.txt")}" end
    local body, err2 = pepe_call("read_file", {path = next_file})
    if err2 then return "failed: " .. err2 end
    return "picked: " .. body
    """

    assert {:ok, "picked: contents of B"} = RunCode.run(%{"script" => script}, %{agent: agent})
  end

  test "pepe_call without a tool name is a Lua-visible error" do
    assert {:ok, out} = RunCode.run(%{"script" => "local _, err = pepe_call(123) return err"}, %{})
    assert out =~ "must be a tool name string"
  end

  test "a misspelled tool name gets a 'did you mean' suggestion from the agent's own tools" do
    agent = %Agent{name: "coder", tools: ["read_file", "write_file"], auto_approve: []}
    script = ~s[local _, err = pepe_call("raed_file", {path = "x"}) return err]

    assert {:ok, out} = RunCode.run(%{"script" => script}, %{agent: agent})
    assert out =~ "unknown tool 'raed_file'"
    assert out =~ "Did you mean 'read_file'?"
  end

  test "a name close to nothing gets a plain unknown-tool error, no wild guess" do
    agent = %Agent{name: "coder", tools: ["read_file", "write_file"], auto_approve: []}
    script = ~s[local _, err = pepe_call("zzqqxx") return err]

    assert {:ok, out} = RunCode.run(%{"script" => script}, %{agent: agent})
    assert out =~ "unknown tool 'zzqqxx'"
    refute out =~ "Did you mean"
  end

  test "a script that fails after a tool call already ran warns the retry about side effects", %{home: home} do
    path = write_tmp!(home, "ran-first.txt", "hello")
    agent = %Agent{name: "coder", auto_approve: ["read_file:reads_outside"]}

    script = """
    local out, err = pepe_call("read_file", {path = "#{path}"})
    local t = nil
    return t.x
    """

    assert {:error, message} = RunCode.run(%{"script" => script}, %{agent: agent})
    assert message =~ "1 tool call(s) already ran in this script before it failed"
    assert message =~ "side effects"
  end

  test "a script that fails before any tool call succeeded carries no retry warning" do
    assert {:error, message} = RunCode.run(%{"script" => ~s[error("boom")]}, %{})
    refute message =~ "already ran"
  end

  test "a script cannot call run_code recursively" do
    script = ~s[local _, err = pepe_call("run_code", {script = "return 1"}) return err]
    agent = %Agent{name: "coder", auto_approve: ["*"]}
    assert {:ok, out} = RunCode.run(%{"script" => script}, %{agent: agent})
    assert out =~ "cannot call itself"
  end

  ###
  ### the security boundary - every refusal below goes through the real
  ### Pepe.Permissions.gate/3, with the call's real name and args
  ###

  test "a tool outside auto_approve is refused inside the sandbox and never runs", %{home: home} do
    target = tmp_path(home, "never-written.txt")
    agent = %Agent{name: "coder", auto_approve: []}

    # An :authorize callback is present, exactly as on an interactive surface - and it
    # must NOT be consulted: a script has no human mid-execution, so the bridge strips it
    # rather than letting the gate escalate to a prompt.
    ctx = %{agent: agent, authorize: fn _n, _a, _c -> flunk("the sandbox must never ask a human") end}

    script = """
    local out, err = pepe_call("write_file", {path = "#{target}", content = "pwned"})
    if err then return "refused: " .. err end
    return "ran: " .. out
    """

    assert {:ok, out} = RunCode.run(%{"script" => script}, ctx)
    assert out =~ "refused:"
    # The script-internal refusal is a "never asked" denial (nobody is promptable
    # mid-script), told apart from a human's explicit no - and it never parks a pending
    # approval either (the bridge opts out): the model retries the tool directly instead.
    assert out =~ "never shown to a human"
    refute out =~ "parked for a human's approval"
    refute File.exists?(target), "the gated tool must never have actually run"
  end

  test "the gate is per-call, not a static allowlist: a grant's risk scope still applies", %{home: home} do
    # `bash:none` covers only risk-free bash calls. A static tool-name allowlist computed
    # once up front would let both calls below through; the real gate, called fresh with
    # each call's actual command, allows the harmless one and refuses the delete.
    victim = Path.join(home, "victim-dir")
    File.mkdir_p!(victim)
    File.write!(Path.join(victim, "keep.txt"), "keep")
    agent = %Agent{name: "coder", auto_approve: ["bash:none"]}

    script = """
    local ok_out, ok_err = pepe_call("bash", {command = "echo harmless"})
    local rm_out, rm_err = pepe_call("bash", {command = "rm -rf #{victim}"})
    if ok_err then return "harmless call failed: " .. ok_err end
    if rm_err then return "OK|" .. ok_out .. "|" .. rm_err end
    return "DELETED"
    """

    assert {:ok, out} = RunCode.run(%{"script" => script}, %{agent: agent})
    assert out =~ "OK|"
    assert out =~ "harmless"
    assert out =~ "never shown to a human"
    refute out =~ "DELETED"
    assert File.exists?(Path.join(victim, "keep.txt")), "the refused rm must never have actually run"
  end

  test "the untrusted-content taint suspends auto_approve inside the sandbox too", %{home: home} do
    target = tmp_path(home, "tainted-touch.txt")
    agent = %Agent{name: "coder", auto_approve: ["bash:any"]}
    script = ~s[local out, err = pepe_call("bash", {command = "touch #{target}"}) if err then return "refused: " .. err end return out]

    # Untainted, the blanket bash grant lets the script run the command.
    assert {:ok, out} = RunCode.run(%{"script" => script}, %{agent: agent})
    assert out =~ "exit_status=0"
    assert File.exists?(target)
    File.rm!(target)

    # The run ingests content from a stranger - now the exact same pre-approved call is
    # refused inside the sandbox, same as it would be outside it: taint disables
    # auto_approve, and with no human mid-script there is nobody to fall back to.
    Permissions.taint()

    assert {:ok, out} = RunCode.run(%{"script" => script}, %{agent: agent})
    assert out =~ "refused:"
    assert out =~ "content from outside"
    refute File.exists?(target), "the tainted call must never have actually run"
  end

  test "a taint picked up mid-script withdraws auto_approve for the rest of the script - and outlives it", %{home: home} do
    # `db_query` is outside content (Pepe.Agent.Runtime's own list): once the script calls
    # it, the bash call AFTER it in the same script must be refused, even though the very
    # same bash call would have been allowed before - and the parent run stays tainted.
    target = tmp_path(home, "post-taint-touch.txt")
    agent = %Agent{name: "coder", auto_approve: ["db_query:any", "bash:any"]}

    script = """
    pepe_call("db_query", {query = "SELECT 1"})
    local out, err = pepe_call("bash", {command = "touch #{target}"})
    if err then return "refused: " .. err end
    return out
    """

    refute Permissions.tainted?(%{})
    assert {:ok, out} = RunCode.run(%{"script" => script}, %{agent: agent})
    assert out =~ "refused:"
    refute File.exists?(target)
    assert Permissions.tainted?(%{}), "the taint the script picked up must survive into the parent run"
  end
end

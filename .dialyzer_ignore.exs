[
  {"lib/pepe/gettext.ex", "Type mismatch in call without opaque term in plural."},
  # luerl (untyped Erlang, no dialyzer specs on its public API) makes dialyzer infer
  # :luerl.do_dec/2's success type as only its {:ok, ...} shape, so it considers the
  # {:lua_error, ...}/{:error, ...} case clauses in run_code.ex's execute/2 (and the
  # error-formatting functions only reachable from them) dead code. They are not: a
  # real Lua runtime error live-triggers this exact path, hint text included, as
  # verified against the real interpreter this session.
  {"lib/pepe/tools/run_code.ex", "Function lua_error_message/1 will never be called."},
  {"lib/pepe/tools/run_code.ex", "Function render_output/1 will never be called."},
  {"lib/pepe/tools/run_code.ex", "Function truncate/1 will never be called."},
  {"lib/pepe/tools/run_code.ex", "Function safe_truncate/2 will never be called."},
  {"lib/pepe/tools/run_code.ex", "Function format_lua_error/1 will never be called."},
  {"lib/pepe/tools/run_code.ex", "Function format_issues/1 will never be called."},
  # sandbox_main/4 deliberately never returns normally - it always calls exit({:done,
  # ...}) so the linked, trapping parent task can tell a real completion apart from a
  # :max_heap_size kill via the EXIT reason. Dialyzer sees the spawned closure as
  # "no local return" because it can't infer that exit/1 is the intended channel here.
  {"lib/pepe/tools/run_code.ex", "The created anonymous function has no local return."},
  # Root cause of the above: luerl declares :luerl.do_dec/2's second argument as an
  # opaque luerlstate(), but dialyzer's success typing traced from luerl's own compiled
  # code infers a concrete tuple shape instead - the two don't reconcile, so dialyzer
  # claims the call (and everything only reachable after it) can never succeed. It
  # does: this session ran real Lua scripts through it repeatedly, including live
  # runtime-error cases that exercise the branches dialyzer thinks are dead.
  {"lib/pepe/tools/run_code.ex", :call}
]

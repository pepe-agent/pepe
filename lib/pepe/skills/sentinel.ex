defmodule Pepe.Skills.Sentinel do
  @moduledoc """
  Static security scan for content **before it's installed or trusted**, in two modes:

    * `scan/1` - **skill markdown** (text the agent later follows as instructions): a
      pattern scan for prompt injection, shell exfiltration, destructive commands,
      persistence, and obfuscation.
    * `scan_code/2` - **plugin Elixir** (code that actually runs with full access): a
      deep **AST walk** that flags dangerous calls precisely (shelling out, dynamic
      eval, unsafe deserialization, destructive filesystem, atom exhaustion, reading
      the environment/secrets, network), plus a text pass for sensitive paths and
      obfuscated blobs. Because it reads the parse tree, it sees `System.cmd`,
      `apply(System, :cmd, ...)`, and aliased/erlang forms alike, and it does not trip
      over the same words appearing in comments or strings.

  It flags; it never blocks anything itself. Verdicts: `:safe`, `:caution` (often
  legitimate, read it), `:danger` (no good reason to be here). No code is executed.
  """

  @type verdict :: :safe | :caution | :danger
  @type finding :: %{
          severity: verdict(),
          category: String.t(),
          match: String.t(),
          line: non_neg_integer(),
          file: String.t() | nil
        }

  # --- skill markdown patterns (text) -----------------------------------------------

  @patterns [
    {:danger, "exfiltration", ~r/\b(curl|wget)\b[^\n]{0,80}\$\{?(?:[A-Z0-9_]*_)?(?:TOKEN|SECRET|KEY|PASSWORD|API_KEY)\}?/i},
    {:danger, "exfiltration", ~r/\bcat\s+~?\/?\.(ssh|aws|gnupg)\//i},
    {:danger, "exfiltration", ~r/\b(cat|read_file)\b[^\n]{0,40}(id_rsa|credentials|\.env\b)/i},
    {:danger, "prompt-injection", ~r/ignore\s+(all\s+)?(previous|prior|above)\s+instructions/i},
    {:danger, "prompt-injection", ~r/disregard\s+(your|all)\s+(previous\s+)?instructions/i},
    {:danger, "prompt-injection", ~r/\bdo\s+not\s+(tell|inform|mention\s+to)\s+the\s+user\b/i},
    {:danger, "prompt-injection", ~r/\byou\s+are\s+now\s+(DAN|in\s+developer\s+mode)\b/i},
    {:caution, "hidden-content", ~r/display:\s*none/i},
    {:caution, "hidden-content", ~r/<!--.*(ignore|instead|actually).*-->/is},
    {:danger, "destructive", ~r/\brm\s+-[a-z]*r[a-z]*f\b/i},
    {:danger, "destructive", ~r/\bgit\s+push\s+(-f|--force)\b/i},
    {:danger, "destructive", ~r/\bDROP\s+(TABLE|DATABASE)\b/i},
    {:danger, "destructive", ~r/:(){ ?:\|:& ?};:/},
    {:danger, "persistence", ~r/\bcrontab\s+-/i},
    {:danger, "persistence", ~r/>>\s*~?\/?\.(bashrc|zshrc|profile|bash_profile)\b/i},
    {:danger, "persistence", ~r/\b(CLAUDE|AGENTS?|SOUL|IDENTITY)\.md\b[^\n]{0,40}(write|append|edit)/i},
    {:caution, "obfuscation", ~r/\bbase64\s+-d(ecode)?\b[^\n]{0,40}\|\s*(sh|bash|python)/i},
    {:caution, "obfuscation", ~r/\beval\s*\(/i}
  ]

  # --- plugin code: dangerous calls (matched on the AST, by {module, function}) ------

  @code_calls %{
    {"System", "cmd"} => {:danger, "shell-exec"},
    {"System", "shell"} => {:danger, "shell-exec"},
    {":os", "cmd"} => {:danger, "shell-exec"},
    {"Port", "open"} => {:danger, "spawn-process"},
    {":erlang", "open_port"} => {:danger, "spawn-process"},
    {"System", "halt"} => {:danger, "halts-the-app"},
    {"System", "stop"} => {:danger, "halts-the-app"},
    {"Code", "eval_string"} => {:danger, "dynamic-eval"},
    {"Code", "eval_quoted"} => {:danger, "dynamic-eval"},
    {"Code", "eval_file"} => {:danger, "dynamic-eval"},
    {"Code", "compile_string"} => {:danger, "dynamic-eval"},
    {"Code", "compile_quoted"} => {:danger, "dynamic-eval"},
    {"Code", "require_file"} => {:danger, "dynamic-eval"},
    {":erlang", "binary_to_term"} => {:danger, "unsafe-deserialize"},
    {"File", "rm_rf"} => {:danger, "destructive-fs"},
    {"File", "rm_rf!"} => {:danger, "destructive-fs"},
    {"File", "rm"} => {:caution, "destructive-fs"},
    {"File", "rm!"} => {:caution, "destructive-fs"},
    {":file", "delete"} => {:caution, "destructive-fs"},
    {"String", "to_atom"} => {:danger, "atom-exhaustion"},
    {"List", "to_atom"} => {:danger, "atom-exhaustion"},
    {":erlang", "binary_to_atom"} => {:caution, "atom-exhaustion"},
    {"System", "get_env"} => {:caution, "reads-env"},
    {"System", "put_env"} => {:caution, "writes-env"},
    {"Node", "connect"} => {:danger, "distribution"},
    {"Node", "spawn"} => {:danger, "distribution"},
    {"Node", "spawn_link"} => {:danger, "distribution"},
    {"Req", "post"} => {:caution, "network"},
    {"Req", "get"} => {:caution, "network"},
    {"Req", "request"} => {:caution, "network"},
    {"Req", "put"} => {:caution, "network"},
    {"HTTPoison", "post"} => {:caution, "network"},
    {":httpc", "request"} => {:caution, "network"},
    {":gen_tcp", "connect"} => {:caution, "network"}
  }

  # Bare (unqualified) calls worth flagging.
  @bare_calls %{"apply" => {:caution, "dynamic-dispatch"}}

  # Text patterns applied to plugin source (things the AST can't see: string literals).
  @code_text_patterns [
    {:danger, "reads-secrets", ~r/\.(ssh|aws|gnupg)\b/},
    {:danger, "reads-secrets", ~r/\b(id_rsa|id_ed25519|credentials)\b|\.env\b/},
    {:danger, "reads-secrets", ~r/\.pepe\/config\.json/},
    {:danger, "obfuscation", ~r/Base\.decode(64|32|16)[^\n]{0,80}(eval|compile|binary_to_term)/},
    {:caution, "obfuscation", ~r/Base\.decode(64|32|16)!?\s*\(/}
  ]

  @doc """
  Scan skill **markdown** text. Returns findings and an overall verdict (the worst
  individual finding's severity).
  """
  @spec scan(String.t()) :: %{verdict: verdict(), findings: [finding()]}
  def scan(text) when is_binary(text) do
    findings = text |> text_findings(@patterns) |> dedupe()
    %{verdict: overall(findings), findings: findings}
  end

  @doc """
  Deep scan of plugin **Elixir source**: an AST walk for dangerous calls plus a text
  pass for sensitive paths and obfuscation. `file` labels findings for a multi-file scan.
  """
  @spec scan_code(String.t(), String.t() | nil) :: %{verdict: verdict(), findings: [finding()]}
  def scan_code(source, file \\ nil) when is_binary(source) do
    findings =
      (ast_findings(source, file) ++ text_findings(source, @code_text_patterns, file)) |> dedupe()

    %{verdict: overall(findings), findings: findings}
  end

  @doc "Merge several scan results into one (worst verdict, all findings)."
  def merge(results) do
    findings = results |> Enum.flat_map(& &1.findings) |> dedupe()
    %{verdict: overall(findings), findings: findings}
  end

  # --- AST analysis -----------------------------------------------------------------

  defp ast_findings(source, file) do
    case Code.string_to_quoted(source, columns: false) do
      {:ok, ast} ->
        {_ast, acc} =
          Macro.prewalk(ast, [], fn node, acc ->
            case call_danger(node, file) do
              nil -> {node, acc}
              finding -> {node, [finding | acc]}
            end
          end)

        Enum.reverse(acc)

      _ ->
        # Unparseable source: the compile step will reject it; fall back to text only.
        []
    end
  end

  # A qualified call: `Module.fun(...)` or `:mod.fun(...)`.
  defp call_danger({{:., _, [mod, fun]}, meta, args}, file) when is_atom(fun) and is_list(args) do
    case module_name(mod) do
      nil -> nil
      module -> lookup(@code_calls, {module, Atom.to_string(fun)}, "#{module}.#{fun}", meta, file)
    end
  end

  # A bare call: `apply(...)`, etc. (`args` is a list; a variable's third element is an atom.)
  defp call_danger({fun, meta, args}, file) when is_atom(fun) and is_list(args) do
    lookup(@bare_calls, Atom.to_string(fun), Atom.to_string(fun), meta, file)
  end

  defp call_danger(_node, _file), do: nil

  defp lookup(table, key, label, meta, file) do
    case Map.get(table, key) do
      {severity, category} ->
        %{severity: severity, category: category, match: label, line: meta[:line] || 0, file: file}

      _ ->
        nil
    end
  end

  defp module_name({:__aliases__, _, parts}), do: Enum.map_join(parts, ".", &Atom.to_string/1)
  defp module_name(mod) when is_atom(mod), do: ":" <> Atom.to_string(mod)
  defp module_name(_), do: nil

  # --- text analysis ----------------------------------------------------------------

  defp text_findings(text, patterns, file \\ nil) do
    lines = String.split(text, "\n")

    for {severity, category, regex} <- patterns,
        {line, idx} <- Enum.with_index(lines, 1),
        match = Regex.run(regex, line),
        match != nil do
      %{severity: severity, category: category, match: hd(match) |> String.slice(0, 80), line: idx, file: file}
    end
  end

  defp dedupe(findings) do
    findings
    |> Enum.uniq_by(&{&1.file, &1.category, &1.line})
    |> Enum.sort_by(&{&1.file || "", &1.line})
  end

  defp overall([]), do: :safe

  defp overall(findings) do
    if Enum.any?(findings, &(&1.severity == :danger)), do: :danger, else: :caution
  end

  @doc "Render findings as a short human-readable report."
  def report(%{verdict: :safe}), do: "✅ No security concerns found."

  def report(%{verdict: verdict, findings: findings}) do
    icon = if verdict == :danger, do: "🚫", else: "⚠️"

    header =
      case verdict do
        :danger -> "#{icon} DANGER - do not install without explicit review:"
        :caution -> "#{icon} Caution - review these before trusting it:"
      end

    header <> "\n" <> Enum.map_join(findings, "\n", &line/1)
  end

  defp line(f) do
    where = if f.file, do: "#{f.file}:#{f.line}", else: "line #{f.line}"
    "  #{where} [#{f.category}]: #{f.match}"
  end
end

defmodule Pepe.Skills.Sentinel do
  @moduledoc """
  Static security scan for skill content **before it's installed or trusted**.

  A skill is a Markdown file the agent later *follows as instructions* — so
  installing one from outside the project is executing someone else's text. This
  scans for the shapes of attack that show up in that text: prompt injection,
  secret exfiltration, destructive commands, persistence, obfuscation.

  Pattern-based and deliberately simple (no AST, no execution) — a fast, dependency
  free first line of defense. It flags; it never blocks anything itself. Verdicts:

    * `:safe`    — nothing matched.
    * `:caution` — matched a pattern that's often legitimate (e.g. `curl`); read it.
    * `:danger`  — matched a pattern with no good reason to be in a skill.

  Used by the `install-skill` skill (via `Pepe.Skills.Sentinel.scan/1`) as a second,
  programmatic check alongside the agent's own read-through.
  """

  @type verdict :: :safe | :caution | :danger
  @type finding :: %{
          severity: verdict(),
          category: String.t(),
          match: String.t(),
          line: pos_integer()
        }

  # {severity, category, regex}. Order doesn't matter; findings are deduped by category.
  @patterns [
    # --- exfiltration: sending local secrets/files somewhere external ---
    {:danger, "exfiltration",
     ~r/\b(curl|wget)\b[^\n]{0,80}\$\{?(?:[A-Z0-9_]*_)?(?:TOKEN|SECRET|KEY|PASSWORD|API_KEY)\}?/i},
    {:danger, "exfiltration", ~r/\bcat\s+~?\/?\.(ssh|aws|gnupg)\//i},
    {:danger, "exfiltration", ~r/\b(cat|read_file)\b[^\n]{0,40}(id_rsa|credentials|\.env\b)/i},

    # --- prompt injection: text trying to redirect the agent reading it ---
    {:danger, "prompt-injection", ~r/ignore\s+(all\s+)?(previous|prior|above)\s+instructions/i},
    {:danger, "prompt-injection", ~r/disregard\s+(your|all)\s+(previous\s+)?instructions/i},
    {:danger, "prompt-injection", ~r/\bdo\s+not\s+(tell|inform|mention\s+to)\s+the\s+user\b/i},
    {:danger, "prompt-injection", ~r/\byou\s+are\s+now\s+(DAN|in\s+developer\s+mode)\b/i},
    {:caution, "hidden-content", ~r/display:\s*none/i},
    {:caution, "hidden-content", ~r/<!--.*(ignore|instead|actually).*-->/is},

    # --- destructive commands ---
    {:danger, "destructive", ~r/\brm\s+-[a-z]*r[a-z]*f\b/i},
    {:danger, "destructive", ~r/\bgit\s+push\s+(-f|--force)\b/i},
    {:danger, "destructive", ~r/\bDROP\s+(TABLE|DATABASE)\b/i},
    {:danger, "destructive", ~r/:(){ ?:\|:& ?};:/},

    # --- persistence: trying to survive/spread beyond this one skill run ---
    {:danger, "persistence", ~r/\bcrontab\s+-/i},
    {:danger, "persistence", ~r/>>\s*~?\/?\.(bashrc|zshrc|profile|bash_profile)\b/i},
    {:danger, "persistence",
     ~r/\b(CLAUDE|AGENTS?|SOUL|IDENTITY)\.md\b[^\n]{0,40}(write|append|edit)/i},

    # --- obfuscation ---
    {:caution, "obfuscation", ~r/\bbase64\s+-d(ecode)?\b[^\n]{0,40}\|\s*(sh|bash|python)/i},
    {:caution, "obfuscation", ~r/\beval\s*\(/i}
  ]

  @doc """
  Scan skill markdown text. Returns findings (possibly empty) and an overall
  verdict — the worst individual finding's severity.
  """
  @spec scan(String.t()) :: %{verdict: verdict(), findings: [finding()]}
  def scan(text) when is_binary(text) do
    lines = String.split(text, "\n")

    findings =
      for {severity, category, regex} <- @patterns,
          {line, idx} <- Enum.with_index(lines, 1),
          match = Regex.run(regex, line),
          match != nil do
        %{
          severity: severity,
          category: category,
          match: hd(match) |> String.slice(0, 80),
          line: idx
        }
      end
      |> Enum.uniq_by(&{&1.category, &1.line})
      |> Enum.sort_by(& &1.line)

    %{verdict: overall(findings), findings: findings}
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
        :danger -> "#{icon} DANGER — do not install without explicit review:"
        :caution -> "#{icon} Caution — review these before installing:"
      end

    header <>
      "\n" <> Enum.map_join(findings, "\n", &"  line #{&1.line} [#{&1.category}]: #{&1.match}")
  end
end

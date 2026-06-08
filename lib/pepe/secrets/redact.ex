defmodule Pepe.Secrets.Redact do
  @moduledoc """
  Mask secret-*shaped* substrings in text the agent produced, even when Pepe does not know the
  value.

  `Pepe.Tools` already strips the exact values of every secret Pepe *holds* (each `${VAR}` the
  config references, the vault tokens, the exposed ones). That cannot catch a secret the agent
  *fetched* - a database password it read with `op read`, an API key in a response body, a
  `Bearer` header it printed - because Pepe never learns those values.

  So this closes the gap the other way: by **shape**. A run of text that reads like a
  credential (`PGPASSWORD=…`, `"api_key": "…"`, `Authorization: Bearer …`, a JWT, a bot token)
  is masked before the tool result reaches the model or the trace on disk, keeping a short
  hint (`abcd…wxyz`) so the output is still readable. It is heuristic, not perfect, and it errs
  toward masking - which is why it is a single pass with a config off-switch
  (`Pepe.Config.redact_tool_output?/0`, on by default), not a promise.
  """

  @keep 4
  @hint_min 16

  # Each rule masks the value part of a match. `:tail` masks capture 2 (a `key = value` where the
  # key names a secret); `:whole` masks capture 1 (a standalone token recognizable on its own).
  #
  # Built at call time, not as a module attribute: OTP 28 compiled regexes hold a NIF resource
  # that cannot be escaped into a module attribute. The cost is negligible next to the tool call
  # whose output is being scrubbed.
  defp rules do
    [
      # Whole-token shapes first, so a header like `Authorization: Bearer <token>` masks the
      # token, before the key=value rules below could mistake the scheme word for the value.
      {~r/(\b[Bb]earer\s+)([A-Za-z0-9._~+\/-]{12,}=*)/, :tail},
      {~r/(\b[Bb]asic\s+)([A-Za-z0-9+\/]{12,}=*)/, :tail},

      # A JWT (three base64url segments; starts with the `eyJ` of `{"`).
      {~r/\b(eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,4096})\b/, :whole},

      # `id:secret` shape - a Telegram bot token and anything built like one.
      {~r/\b(\d{6,}:[A-Za-z0-9_-]{20,})\b/, :whole},

      # An UPPER_SNAKE env var containing a secret word - `PGPASSWORD=…`, `GH_TOKEN=…`,
      # `AWS_SECRET_ACCESS_KEY=…`. TOKEN/SECRET/PASSWORD/PASSWD never collide with an English
      # word, so they are safe to match glued. The name runs are bounded (`{0,64}`, not `*`) so a
      # long run of capitals cannot make the two adjacent classes backtrack quadratically - real
      # env names are short, and this keeps every pattern here linear-time (ReDoS-safe).
      {~r/(\b[A-Z0-9_]{0,64}(?:TOKEN|SECRET|PASSWORD|PASSWD)[A-Z0-9_]{0,64}\b\s*[=:]\s*["']?)([^\s"',;&«»…]{6,4096})/, :tail},

      # ...a KEY var, but only where KEY is a real part (`_KEY`, `API_KEY`), so `MONKEY`, `DONKEY`
      # and `TURKEY` are left alone - the same word-part rule `Pepe.Secrets.secret_key?/1` uses.
      {~r/(\b[A-Z0-9_]{0,64}(?:_KEY|API_?KEY)\b\s*[=:]\s*["']?)([^\s"',;&«»…]{6,4096})/, :tail},

      # A key named as a secret (whole word, any case) in `k=v`, `k: v`, or `"k":"v"`.
      {~r/(\b(?:password|passwd|pwd|api[-_]?key|apikey|secret|access[-_]?token|refresh[-_]?token|client[-_]?secret|app[-_]?secret|credential|private[-_]?key|auth[-_]?token|token)\b["']?\s*[=:]\s*["']?)([^\s"',;&«»…]{6,4096})/i,
       :tail}
    ]
  end

  @doc "Mask secret-shaped substrings in `text`. Non-binaries pass through untouched."
  @spec scrub(term()) :: term()
  def scrub(text) when is_binary(text) do
    Enum.reduce(rules(), text, fn {re, kind}, acc -> apply_rule(acc, re, kind) end)
  end

  def scrub(text), do: text

  defp apply_rule(text, re, :tail) do
    Regex.replace(re, text, fn _full, prefix, value -> prefix <> mask(value) end)
  end

  defp apply_rule(text, re, :whole) do
    Regex.replace(re, text, fn _full, value -> mask(value) end)
  end

  # A long, high-entropy value keeps a first/last hint (you cannot rebuild it from 8 of 40
  # characters, and the hint keeps logs debuggable); a short one is blanked outright.
  defp mask(value) do
    if String.length(value) >= @hint_min do
      String.slice(value, 0, @keep) <> "…" <> String.slice(value, -@keep, @keep)
    else
      "***"
    end
  end
end

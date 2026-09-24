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

  # Fallback for a secret with no recognizable shape at all - a raw API key pasted with no
  # `KEY=`/`Bearer ` in front of it, a password printed bare. None of the rules above look at
  # how random a string actually *is*, only at what surrounds it, so this scores entropy per
  # rune on long token-shaped runs and masks whatever clears the bar - after the shape rules
  # above have already run, so this only ever sees what they left untouched.
  @entropy_min_length 28
  @entropy_bits_per_rune 3.6

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
    rules()
    |> Enum.reduce(text, fn {re, kind}, acc -> apply_rule(acc, re, kind) end)
    |> scrub_high_entropy()
  end

  def scrub(text), do: text

  # Same "not a module attribute" reason as `rules/0` above - this is Regex.compile'd fresh
  # per call.
  defp entropy_candidate_regex, do: ~r/[A-Za-z0-9+\/=_.~-]{#{@entropy_min_length},4096}/

  defp scrub_high_entropy(text) do
    Regex.replace(entropy_candidate_regex(), text, fn candidate ->
      if secret_like_entropy?(candidate), do: mask(candidate), else: candidate
    end)
  end

  # Excludes the shapes real tool output is full of that would otherwise cross the entropy bar
  # just as an actual secret does:
  #
  #   * A UUID and a hex hash/checksum/commit SHA both read as "random" to an entropy score just
  #     as much as a secret does, entropy alone cannot tell them apart, so pure-hex candidates
  #     are left to the shape rules above (which already catch a *named* hex secret via `KEY=`/
  #     `TOKEN=`) rather than guessed at here.
  #   * A path is excluded by a cheaper, more legible signal than trying to entropy-score it:
  #     real secrets padded to base64 almost always carry a `+` or `=` somewhere in this length
  #     range and rarely have more than one `/`, an ordinary path is the opposite of both.
  #   * A long snake_case/dotted identifier or hostname (`Pepe.Config.redact_tool_output`,
  #     `ec2-54-12-34-56.compute-1.amazonaws.com`) is not one random run at all - it is several
  #     short, ordinary words glued by `.`/`_`/`-`. Scoring the *segments* those delimiters
  #     imply, not just the candidate as a whole, is what tells the two apart without a coarser
  #     "needs a digit and a letter" gate, which would stop catching a lowercase-only or
  #     digit-less base64-style secret just as wrongly.
  defp secret_like_entropy?(candidate) do
    not uuid?(candidate) and not pure_hex?(candidate) and not path_like?(candidate) and
      Enum.any?(word_segments(candidate), &high_entropy_segment?/1)
  end

  defp word_segments(s), do: String.split(s, ~r/[._-]/, trim: true)

  defp high_entropy_segment?(s) do
    String.length(s) >= @entropy_min_length and entropy_bits_per_rune(s) >= @entropy_bits_per_rune
  end

  defp uuid?(s), do: Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, s)

  # `\.?` because the candidate regex includes `.` (a valid token-edge character elsewhere), so
  # a SHA sitting at the end of an ordinary sentence ("...commit a3f5…e8f0.") pulls the closing
  # period into the match. Any other punctuation cannot join at all - it is outside the
  # candidate charset to begin with - so only this one trailing case needs stripping here.
  defp pure_hex?(s), do: Regex.match?(~r/^[0-9a-fA-F]+\.?$/, s)

  # A real secret's `=` is always trailing base64 padding (0-2 characters, per the base64
  # spec); a `NAME=/some/path` assignment (PATH, LD_LIBRARY_PATH, ...) also contains an `=`,
  # but nowhere near the end - it is the key/value separator near the *start*. Checking where
  # the `=` sits, not just whether one exists, is what tells these two apart. The slash count
  # is the other half: a genuine path almost always has several (`/usr/local/bin`), while a
  # single `/` landing inside an otherwise unbroken token (valid in both base64 and base64url)
  # is far more likely to be that token than a path with exactly one component.
  defp path_like?(s), do: slash_count(s) >= 2 and not String.contains?(s, "+") and not trailing_padding?(s)

  defp slash_count(s), do: s |> String.split("/") |> length() |> Kernel.-(1)

  defp trailing_padding?(s) do
    trimmed = String.trim_trailing(s, "=")
    trimmed != s and not String.contains?(trimmed, "=")
  end

  defp entropy_bits_per_rune(s) do
    graphemes = String.graphemes(s)
    total = length(graphemes)

    graphemes
    |> Enum.frequencies()
    |> Enum.reduce(0.0, fn {_g, count}, acc ->
      p = count / total
      acc - p * :math.log2(p)
    end)
  end

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

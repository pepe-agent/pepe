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
  # per call. No upper bound on the repeat count: capping it (an earlier version capped at
  # 4096) truncates the *match*, not just a length the caller stops caring about past - a
  # secret longer than the cap would have its tail split into a second, separately-matched-and-
  # masked candidate, but a tail shorter than the minimum length after the cut point isn't a
  # candidate at all and passes through raw. A plain character-class repeat has no
  # backtracking to blow up regardless of how high the bound goes (verified: 600,000 chars
  # scans in under a millisecond), so there is no performance reason to keep one either.
  defp entropy_candidate_regex, do: ~r/[A-Za-z0-9+\/=_.~-]{#{@entropy_min_length},}/

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
  #     short, ordinary words glued by `.`/`_`/`-`. What actually marks a piece of it as an
  #     ordinary word rather than random data is its *case structure*: `redact`, `tool`,
  #     `Config` are each all-lowercase, all-uppercase, or Capitalized - a single, predictable
  #     case run - never the chaotic per-character case switching (`qW2mK7pL4n`) an actual
  #     mixed-case secret has. Splitting into segments and requiring *every one* to have that
  #     plain, predictable shape (not each one to independently clear the length bar, which a
  #     real secret glued together by `-`/`_` - valid base64url alphabet characters, not word
  #     separators there - could dodge just by being split into short-enough pieces) is what
  #     tells the two apart without a coarser "needs a digit and a letter" gate, which would
  #     stop catching a lowercase-only or digit-less base64-style secret just as wrongly. A
  #     candidate with no `.`/`_`/`-` at all (nothing to split on) is judged on its own; this
  #     only ever gates a *multi-segment* run.
  #
  # Entropy itself is scored over a sliding window, not the whole candidate at once: a
  # real secret glued directly (no delimiter at all, so nothing for word_segments/identifier_like?
  # to key off) to a long, low-entropy run - 32 zero characters, say - would otherwise have its
  # own high entropy averaged down by that filler across the *whole* candidate and never clear
  # the bar, even though a full-length substring of it is exactly as random as any other secret
  # this pass catches. Any window clearing the bar on its own is enough to mask the whole match.
  defp secret_like_entropy?(candidate) do
    not uuid?(candidate) and not pure_hex?(candidate) and not path_like?(candidate) and
      not identifier_like?(candidate) and has_high_entropy_window?(candidate)
  end

  # A tuple, not repeated `String.slice/3` calls: slicing a binary at an arbitrary offset walks
  # it from the start to find the right grapheme boundary, so slicing at every one of up to
  # `len` positions is O(len) work each - the sliding window this exists for turns that into
  # O(len²) overall (confirmed: the 200,000-character ReDoS-safety test went from under a
  # second to over 18). `elem/2` on a tuple is O(1), keeping the whole scan O(len) again.
  defp has_high_entropy_window?(s) do
    graphemes = s |> String.graphemes() |> List.to_tuple()
    len = tuple_size(graphemes)

    len >= @entropy_min_length and
      Enum.any?(0..(len - @entropy_min_length), &high_entropy_at?(graphemes, &1))
  end

  defp high_entropy_at?(graphemes, start) do
    window = for i <- start..(start + @entropy_min_length - 1), do: elem(graphemes, i)
    entropy_of_graphemes(window) >= @entropy_bits_per_rune
  end

  defp word_segments(s), do: String.split(s, ~r/[._-]/, trim: true)

  defp identifier_like?(s) do
    case word_segments(s) do
      [_single] -> false
      segments -> Enum.all?(segments, &plain_word_segment?/1)
    end
  end

  # `(?:[A-Z][a-z]*)+` (not just one leading capital) so a compound PascalCase/CamelCase module
  # or type name - `SkillLearning`, `ExternalContent` - counts as plain too; it is still several
  # ordinary Capitalized words, just glued without a delimiter between them, and a single-
  # capital-only rule flagged the second word's capital as the chaotic mid-string case switching
  # a real secret has. Digits are allowed only as a *trailing* run on a letter branch (`ec2`,
  # `sha256`), never interleaved through the letters (`k9m7p3q8`) - a real word takes a digit
  # suffix or acronym tail, it does not alternate letter/digit every couple of characters the
  # way an encoded secret that happens to fall on the lowercase-alphanumeric branch can. A
  # standalone all-digit segment (`54` in an IP octet) is its own branch, not folded into the
  # letter ones, since it has no letters to require any of.
  defp plain_word_segment?(s), do: Regex.match?(~r/^(?:(?:[A-Z][a-z]*)+[0-9]*|[a-z]+[0-9]*|[A-Z]+[0-9]*|[0-9]+)$/, s)

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
  #
  # Known, accepted gap: an *unpadded* secret with exactly two `/` (base64url-with-no-padding
  # can legitimately contain them, and two is already the "genuine path" bar) still reads as
  # path-like and slips through. Distinguishing the two by splitting on `/` and demanding every
  # piece look path-plausible hits the identical problem `identifier_like?/1` above exists to
  # avoid on `-`/`_`: a real secret containing `/` can just as easily be split into pieces short
  # enough to dodge a per-piece check. Left as a real, narrower miss rather than guessed at with
  # an unverified heuristic - the module's own moduledoc already calls this pass "heuristic, not
  # perfect."
  defp path_like?(s), do: slash_count(s) >= 2 and not String.contains?(s, "+") and not trailing_padding?(s)

  defp slash_count(s), do: s |> String.split("/") |> length() |> Kernel.-(1)

  defp trailing_padding?(s) do
    trimmed = String.trim_trailing(s, "=")
    trimmed != s and not String.contains?(trimmed, "=")
  end

  defp entropy_of_graphemes(graphemes) do
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

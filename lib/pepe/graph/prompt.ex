defmodule Pepe.Graph.Prompt do
  @moduledoc """
  Pure functions for the two data-only pieces of a node's contract: what its prompt/ask
  renders to given `state`, and what its reply routes to given `verdicts`. No model
  calls, no I/O - kept separate from `Pepe.Graph.Runner` so both are testable without a
  mock server.

  Deliberately minimal templating: a single `{{key}}`-family substitution, never a real
  template language. `{{input}}` reads the run's input string; `{{key}}` reads
  `state[key]` and fails the run on a miss (catches a typo'd reference instead of
  silently sending a half-empty prompt); `{{key?}}` reads `state[key]` and falls back to
  a fixed placeholder on a miss (the one concession a loop-back node needs, since its
  first visit has no upstream reply yet); `{{key|default:"..."}}` falls back to an
  author-chosen literal instead. No conditionals, loops, or expressions - if a prompt
  needs logic, that logic belongs in the node's instructions to the model, not in a
  template language Pepe would have to parse and secure.
  """

  @ref ~r/\{\{([a-z0-9_-]+)(\?)?(?:\|default:"([^"]*)")?\}\}/

  @doc """
  Render `template` against `state` and the run's `input`. Returns `{:ok, rendered}` or
  `{:error, {:unbound_ref, key}}` when a required (non-`?`, no `|default:`) reference
  names a `state` key that hasn't been written yet.
  """
  @spec render(String.t(), map(), String.t() | nil) ::
          {:ok, String.t()} | {:error, {:unbound_ref, String.t()}}
  def render(template, state, input) when is_binary(template) and is_map(state) do
    matches = scan(template)

    case Enum.find_value(matches, &unbound_ref(&1, state)) do
      nil -> {:ok, do_render(template, matches, state, input || "")}
      key -> {:error, {:unbound_ref, key}}
    end
  end

  # `Regex.scan/3` with `return: :index` always returns a fixed-shape index tuple per
  # capture group - `{-1, 0}` for one that didn't participate - unlike the default
  # `return: :binary`, where Erlang's :re drops a TRAILING non-participating group from
  # the result entirely instead of returning "". E.g. `{{draft}}` (no `?`, no
  # `|default:`) would scan as `["{{draft}}", "draft"]`, two elements, not four - a
  # fixed 4-element `[full, key, optional, default]` destructure on that crashes. Index
  # mode sidesteps it since the shape never varies.
  defp scan(template) do
    @ref
    |> Regex.scan(template, return: :index)
    |> Enum.map(fn [full_idx | rest_idx] ->
      [key, optional, default] = rest_idx |> Enum.map(&slice(template, &1)) |> pad(3)
      %{index: full_idx, key: key, optional: optional, default: default}
    end)
  end

  defp slice(_template, {-1, 0}), do: nil
  defp slice(template, {start, len}), do: binary_part(template, start, len)

  defp pad(list, n), do: list ++ List.duplicate(nil, n - length(list))

  defp unbound_ref(%{key: "input"}, _state), do: nil
  defp unbound_ref(%{optional: "?"}, _state), do: nil
  defp unbound_ref(%{default: default}, _state) when not is_nil(default), do: nil
  defp unbound_ref(%{key: key}, state), do: if(Map.has_key?(state, key), do: nil, else: key)

  defp do_render(template, matches, state, input) do
    {chunks, last} =
      Enum.reduce(matches, {[], 0}, fn %{index: {start, len}} = match, {acc, pos} ->
        before = binary_part(template, pos, start - pos)
        {[render_match(match, state, input), before | acc], start + len}
      end)

    tail = binary_part(template, last, byte_size(template) - last)
    [tail | chunks] |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp render_match(%{key: "input"}, _state, input), do: input

  defp render_match(%{key: key} = match, state, _input) do
    cond do
      Map.has_key?(state, key) -> stringify(Map.get(state, key))
      match.optional == "?" -> "(none yet)"
      true -> match.default || ""
    end
  end

  # A node's own past reply is always a plain string, but a graph's initial `state`
  # defaults are author-supplied JSON and can be anything - `to_string/1` raises on a
  # map/list/tuple, so this is total instead of trusting every value to already be a
  # scalar.
  defp stringify(value) when is_binary(value), do: value
  defp stringify(nil), do: ""
  defp stringify(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp stringify(value), do: Jason.encode!(value)

  @doc """
  Every `state` key a template references (via any of the three `{{...}}` forms),
  excluding the special `input` name. Used to compute per-key taint: a node's call is
  only born untrusted if it actually reads a tainted key, not because *some* key
  elsewhere in the run is tainted.
  """
  @spec referenced_keys(String.t() | nil) :: [String.t()]
  def referenced_keys(nil), do: []

  def referenced_keys(template) when is_binary(template) do
    @ref
    |> Regex.scan(template)
    |> Enum.map(fn [_full, key | _] -> key end)
    |> Enum.reject(&(&1 == "input"))
    |> Enum.uniq()
  end

  # `Pepe.Graph.import/2` validates that a `prompt`/`ask`/task/arg value is a string before
  # ever saving it, but this stays a pure function that never raises on a shape it wasn't
  # given, rather than trusting every call site to have checked first.
  def referenced_keys(_not_a_string), do: []

  @doc """
  Resolve a verifier's reply to `{:ok, verdict_word, target_node_or_"end"}`. The
  contract is a fixed final line, not a scan: only the last non-blank line, trimmed,
  lowercased, trailing punctuation stripped, is checked against `verdicts`' keys - a
  reply that merely *mentions* a verdict word mid-text must not route on it.
  """
  @spec verdict(String.t(), map()) :: {:ok, String.t(), String.t()} | {:error, {:bad_verdict, String.t()}}
  def verdict(reply, verdicts) when is_binary(reply) and is_map(verdicts) do
    # `String.split(reply, "\n", trim: true)` only drops segments that are the empty
    # string outright - a trailing line of pure whitespace ("pass\n   \n") survives that
    # and would wrongly become "the last line" instead of "pass". Trim every line first,
    # then drop the ones that are blank only after trimming.
    last_line =
      reply
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.last(reply)
      |> String.replace(~r/[.!?:;,]+$/, "")
      |> String.downcase()

    case Map.fetch(verdicts, last_line) do
      {:ok, target} -> {:ok, last_line, target}
      :error -> {:error, {:bad_verdict, last_line}}
    end
  end
end

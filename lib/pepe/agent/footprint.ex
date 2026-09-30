defmodule Pepe.Agent.Footprint do
  @moduledoc """
  How much of every model call an agent spends before the user says a word.

  Each round of the tool loop re-sends the system prompt and every tool spec, so this
  fixed part is the floor under every turn: a bare "hi" costs at least this much, and a
  ten-step task costs ten times it. `measure/1` splits that floor into the system prompt
  sections and the individual tool specs so the heavy parts are visible.

  Sizes are estimates (bytes / 4), good for comparing parts and before/after, not for
  billing - the provider's own count is in the usage ledger.
  """

  alias Pepe.Agent.Workspace
  alias Pepe.Tools

  @bytes_per_token 4

  @doc "Estimated tokens for a string."
  def tokens(text) when is_binary(text), do: div(byte_size(text) + @bytes_per_token - 1, @bytes_per_token)

  @doc """
  Measure an agent. Returns `%{prompt: [{label, tokens}], tools: [{name, tokens}],
  prompt_total: n, tools_total: n, total: n}`, each list heaviest first.
  """
  def measure(agent) do
    prompt =
      agent
      |> Workspace.system_prompt_sections()
      |> Enum.map(fn {label, text} -> {label, tokens(text)} end)

    tools =
      (agent.tools || [])
      |> Tools.specs()
      |> List.wrap()
      |> Enum.map(fn spec -> {spec_name(spec), tokens(Jason.encode!(spec))} end)

    prompt_total = total(prompt)
    tools_total = total(tools)

    %{
      prompt: Enum.sort_by(prompt, &elem(&1, 1), :desc),
      tools: Enum.sort_by(tools, &elem(&1, 1), :desc),
      prompt_total: prompt_total,
      tools_total: tools_total,
      total: prompt_total + tools_total
    }
  end

  defp total(rows), do: rows |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  defp spec_name(%{"function" => %{"name" => name}}), do: name
  defp spec_name(%{function: %{name: name}}), do: name
  defp spec_name(_), do: "?"
end

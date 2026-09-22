defmodule Pepe.ACP.Updates do
  @moduledoc """
  The `session/update` payloads an editor renders beyond the message text and the tool
  calls: the agent's plan, the context window filling up, the commands it understands,
  the mode it is in.

  Payload builders only - `Pepe.ACP.Server` decides when to send them and
  `Pepe.ACP.Protocol.session_update/2` wraps them in their envelope.
  """

  alias Pepe.Agent.Compaction
  alias Pepe.Config

  @doc """
  A `plan` update from the steps `update_plan` stored (`%{"title", "status"}` maps, in
  order). ACP's plan is replaced whole on every update, which is exactly what the tool
  does too, so an empty list clears the editor's panel.
  """
  @spec plan([map()]) :: map()
  def plan(steps) when is_list(steps) do
    %{
      "sessionUpdate" => "plan",
      "entries" => Enum.map(steps, &plan_entry/1)
    }
  end

  defp plan_entry(%{"title" => title} = step) do
    %{"content" => title, "priority" => "medium", "status" => plan_status(step["status"])}
  end

  defp plan_status("done"), do: "completed"
  defp plan_status("in_progress"), do: "in_progress"
  defp plan_status(_other), do: "pending"

  @doc """
  A `usage_update`: how much of the model's context window the conversation occupies.
  `used` is what the last request cost in tokens (its prompt, which carries the whole
  history, plus what came back) and `size` is the window of the model that answered -
  the numbers an editor draws its context meter from. `nil` when the provider reported
  nothing to measure.
  """
  @spec usage(String.t() | nil, map()) :: map() | nil
  def usage(model_name, usage) when is_map(usage) do
    used = int(usage["prompt_tokens"]) + int(usage["completion_tokens"])
    used = if used > 0, do: used, else: int(usage["total_tokens"])

    with true <- used > 0,
         %{} = model <- model_name && Config.get_model(model_name) do
      %{"sessionUpdate" => "usage_update", "used" => used, "size" => Compaction.window(model)}
    else
      _ -> nil
    end
  end

  def usage(_model_name, _usage), do: nil

  @doc "The token counts of one model call, in the shape a turn's totals are summed from."
  @spec tokens(map()) :: %{input: non_neg_integer(), output: non_neg_integer(), cached: non_neg_integer()}
  def tokens(usage) when is_map(usage) do
    input = int(usage["prompt_tokens"])
    output = int(usage["completion_tokens"])

    {input, output} =
      if input + output == 0, do: {int(usage["total_tokens"]), 0}, else: {input, output}

    cached =
      case int(usage["cached_tokens"]) do
        0 -> int(get_in(usage, ["prompt_tokens_details", "cached_tokens"]))
        n -> n
      end

    %{input: input, output: output, cached: cached}
  end

  @doc "The `usage` object of a `PromptResponse`, from a turn's summed token counts."
  @spec prompt_usage(%{input: integer(), output: integer(), cached: integer()}) :: map() | nil
  def prompt_usage(%{input: input, output: output, cached: cached}) when input + output > 0 do
    base = %{"inputTokens" => input, "outputTokens" => output, "totalTokens" => input + output}
    if cached > 0, do: Map.put(base, "cachedReadTokens", cached), else: base
  end

  def prompt_usage(_totals), do: nil

  @doc """
  An `available_commands_update` with every slash command the agent handles itself, and one
  per installed skill the session's agent is offered (`opts`: its `:agent` and `:cwd`).
  """
  @spec available_commands(keyword()) :: map()
  def available_commands(opts \\ []) do
    %{"sessionUpdate" => "available_commands_update", "availableCommands" => Pepe.ACP.Commands.available(opts)}
  end

  @doc "A `user_message_chunk`: echoes text the editor did not type itself (a queued prompt starting)."
  @spec user_message(String.t()) :: map()
  def user_message(text),
    do: %{"sessionUpdate" => "user_message_chunk", "content" => %{"type" => "text", "text" => text}}

  @doc "A `current_mode_update`, sent when the mode changes by any route."
  @spec current_mode(String.t()) :: map()
  def current_mode(mode_id), do: %{"sessionUpdate" => "current_mode_update", "currentModeId" => mode_id}

  @doc "A `config_option_update` carrying the full option list."
  @spec config_options([map()]) :: map()
  def config_options(options), do: %{"sessionUpdate" => "config_option_update", "configOptions" => options}

  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: round(n)
  defp int(_other), do: 0
end

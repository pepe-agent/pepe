defmodule Pepe.Tools.SendPresentation do
  @moduledoc """
  Send structured content (a table, a row of buttons, a paragraph - see
  `Pepe.Presentation`) to the current conversation, rendered into whatever the channel
  natively supports. Delivered on this conversation's channel automatically, the same
  routing `send_file` uses - the agent doesn't need to know chat ids or tokens.

  A channel that hasn't added native rendering (most, today - see
  `Pepe.Webhooks.Provider.deliver_blocks/3`) still gets the content, just flattened to
  plain text (`Pepe.Presentation.to_text/1`) instead of drawn natively.
  """
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Config
  alias Pepe.Webhooks

  @impl true
  def name, do: "send_presentation"

  @impl true
  def spec do
    function(
      "send_presentation",
      "Send structured content (a table, a row of buttons, or a paragraph) to the current " <>
        "conversation, rendered natively where the channel supports it (e.g. real Slack " <>
        "buttons), otherwise as readable plain text. Reach for this over a plain reply when " <>
        "the content is genuinely tabular or the user needs to pick from a short list of " <>
        "choices - not for ordinary conversational replies.",
      %{
        "type" => "object",
        "properties" => %{
          "blocks" => %{
            "type" => "array",
            "description" => "One or more content blocks, rendered in order.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "type" => %{"type" => "string", "enum" => ["text", "table", "buttons"]},
                "text" => %{"type" => "string", "description" => "For type=text: the paragraph."},
                "headers" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "For type=table."},
                "rows" => %{
                  "type" => "array",
                  "items" => %{"type" => "array", "items" => %{"type" => "string"}},
                  "description" => "For type=table: one array of cell strings per row."
                },
                "buttons" => %{
                  "type" => "array",
                  "description" => "For type=buttons.",
                  "items" => %{
                    "type" => "object",
                    "properties" => %{
                      "label" => %{"type" => "string"},
                      "value" => %{"type" => "string"}
                    },
                    "required" => ["label"]
                  }
                }
              },
              "required" => ["type"]
            }
          }
        },
        "required" => ["blocks"]
      }
    )
  end

  @impl true
  def run(%{"blocks" => blocks}, ctx) do
    if Pepe.Presentation.valid?(blocks) do
      with {:ok, session} <- fetch_session(ctx),
           :ok <- deliver(session, blocks) do
        {:ok, "Sent."}
      end
    else
      {:error, "malformed blocks - each needs a \"type\" of text/table/buttons and its own required fields"}
    end
  end

  def run(_args, _ctx), do: {:error, "send_presentation needs a `blocks` array"}

  # ---- routing -----------------------------------------------------------------------
  # Mirrors Pepe.Tools.SendFile's own routing: Telegram is a separate gateway (not a
  # Pepe.Webhooks.Provider), so it always gets the flattened-to-text fallback - it has no
  # deliver_blocks/3 to opt into. Every other channel goes through Pepe.Webhooks.

  defp deliver("telegram:" <> rest, blocks) do
    normalize(Pepe.Gateways.Telegram.deliver(rest, Pepe.Presentation.to_text(blocks)))
  end

  defp deliver(session, blocks) do
    case String.split(session, ":", parts: 3) do
      [provider, agent, from] ->
        with mod when not is_nil(mod) <- Webhooks.provider(provider),
             {:ok, entry} <- connection_for(provider, agent) do
          normalize(Webhooks.deliver_blocks(mod, entry, from, blocks))
        else
          nil -> {:error, "unknown channel provider #{provider}"}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, "this conversation isn't on a channel that can receive messages this way"}
    end
  end

  defp connection_for(provider, agent) do
    Config.webhooks()
    |> Enum.find(fn {_slug, e} -> e["provider"] == provider and to_string(e["agent"]) == agent end)
    |> case do
      {_slug, entry} -> {:ok, entry}
      _ -> {:error, "no #{provider} connection is bound to agent #{agent}"}
    end
  end

  # ---- helpers -------------------------------------------------------------------------

  defp fetch_session(ctx) do
    case ctx[:session_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, "no conversation channel to send to (this isn't a live chat)"}
    end
  end

  defp normalize(:ok), do: :ok
  defp normalize({:error, reason}), do: {:error, "delivery failed: #{inspect(reason)}"}
  defp normalize(other), do: {:error, "unexpected delivery result: #{inspect(other)}"}
end

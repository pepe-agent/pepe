defmodule Pepe.Tools.SendFile do
  @moduledoc """
  Send a local file to the person in the current conversation, as a channel
  attachment (Telegram document, WhatsApp/Slack/Discord media, ...).

  The agent produces a file however it likes (e.g. a `bash` script that queries a
  database and writes an `.xlsx`), then calls this tool with the file's path. The
  file is delivered on whatever channel this conversation is on, resolved from the
  session key — the agent doesn't need to know chat ids or tokens.
  """
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Config
  alias Pepe.Webhooks

  @impl true
  def name, do: "send_file"

  @impl true
  def spec do
    function(
      "send_file",
      "Send a local file to the current conversation as an attachment (spreadsheet, " <>
        "PDF, image, ...). Create the file first (e.g. with bash), then pass its path. " <>
        "It is delivered on this conversation's channel automatically.",
      %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path to the local file to send."},
          "caption" => %{"type" => "string", "description" => "Optional caption/message to send with the file."}
        },
        "required" => ["path"]
      }
    )
  end

  @impl true
  def run(%{"path" => path} = args, ctx) do
    caption = blank(args["caption"])

    with {:ok, full} <- resolve_path(path, ctx),
         {:ok, session} <- fetch_session(ctx),
         :ok <- deliver(session, full, caption) do
      {:ok, "Sent #{Path.basename(full)} to the conversation."}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_args, _ctx), do: {:error, "send_file needs a `path`"}

  # ---- routing -----------------------------------------------------------------------

  # The gateway's target is the chat id (default bot) or "<bot>:<chat>", i.e. the
  # session key with the leading "telegram:" stripped.
  defp deliver("telegram:" <> rest, path, caption) do
    normalize(Pepe.Gateways.Telegram.deliver_file(rest, path, caption))
  end

  defp deliver(session, path, caption) do
    case String.split(session, ":", parts: 3) do
      [provider, agent, from] ->
        with mod when not is_nil(mod) <- Webhooks.provider(provider),
             true <- Code.ensure_loaded?(mod) and function_exported?(mod, :deliver_file, 4),
             {:ok, entry} <- connection_for(provider, agent) do
          normalize(mod.deliver_file(entry, from, path, caption))
        else
          false -> {:error, "the #{provider} channel can't receive files yet"}
          nil -> {:error, "unknown channel provider #{provider}"}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, "this conversation isn't on a channel that can receive files"}
    end
  end

  # Find the webhook connection this session belongs to (by provider + bound agent).
  defp connection_for(provider, agent) do
    Config.webhooks()
    |> Enum.find(fn {_slug, e} -> e["provider"] == provider and to_string(e["agent"]) == agent end)
    |> case do
      {_slug, entry} -> {:ok, entry}
      _ -> {:error, "no #{provider} connection is bound to agent #{agent}"}
    end
  end

  # ---- helpers -----------------------------------------------------------------------

  defp fetch_session(ctx) do
    case ctx[:session_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, "no conversation channel to send to (this isn't a live chat)"}
    end
  end

  defp resolve_path(path, ctx) do
    full = if Path.type(path) == :absolute, do: path, else: Path.join(ctx[:cwd] || File.cwd!(), path)

    cond do
      not File.exists?(full) -> {:error, "file not found: #{full}"}
      File.dir?(full) -> {:error, "#{full} is a directory, not a file"}
      true -> {:ok, full}
    end
  end

  defp normalize(:ok), do: :ok
  defp normalize({:error, reason}), do: {:error, "delivery failed: #{inspect(reason)}"}
  defp normalize(other), do: {:error, "unexpected delivery result: #{inspect(other)}"}

  defp blank(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank(_), do: nil
end

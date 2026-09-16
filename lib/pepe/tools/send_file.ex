defmodule Pepe.Tools.SendFile do
  @moduledoc """
  Send a local file to the person in the current conversation, as a channel
  attachment (Telegram document, WhatsApp/Slack/Discord media, ...).

  The agent produces a file however it likes (e.g. a `bash` script that queries a
  database and writes an `.xlsx`), then calls this tool with the file's path. The
  file is delivered on whatever channel this conversation is on, resolved from the
  session key - the agent doesn't need to know chat ids or tokens.
  """
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Agent.Workspace
  alias Pepe.Config
  alias Pepe.Webhooks

  # How long a dashboard download link stays valid. Long enough that a chat left open
  # overnight can still fetch the file the next morning; short enough that a workspace
  # cleanup or an agent overwriting the same filename later doesn't quietly serve stale
  # bytes under an old link that outlived its usefulness.
  @download_ttl_s 24 * 60 * 60

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
    end
  end

  def run(_args, _ctx), do: {:error, "send_file needs a `path`"}

  # ---- routing -----------------------------------------------------------------------

  # The gateway's target is the chat id (default bot) or "<bot>:<chat>", i.e. the
  # session key with the leading "telegram:" stripped.
  defp deliver("telegram:" <> rest, path, caption) do
    normalize(Pepe.Gateways.Telegram.deliver_file(rest, path, caption))
  end

  # The dashboard has no bot API to push a document through - a "web:<id>" session key is a
  # ChatLive process, not a channel with its own delivery mechanism. Every other channel gets
  # the file in hand; without this clause the dashboard fell through to the generic "can't
  # receive files yet" error below, and the agent's only way to answer was to read the raw
  # server filesystem path back to a human with no shell access to it - useless. Instead:
  # register the file for a time-boxed download (Pepe.Store, the disposable tier - never
  # the config source of truth for something this transient) under a token nobody could
  # guess, then tell the live chat process to render a download link. Reusable for the
  # full TTL, not one-time - re-downloading the same link twice is a feature, not a leak,
  # since it's already behind the dashboard's own auth gate. The file itself is never
  # copied or re-encoded; the controller streams it straight off disk.
  defp deliver("web:" <> _ = key, path, caption) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    filename = Path.basename(path)
    Pepe.Store.put(:dashboard_download, token, %{path: path, filename: filename}, ttl: @download_ttl_s)

    Phoenix.PubSub.broadcast(Pepe.PubSub, "session:" <> key, {:session_event, key, {:file_ready, token, filename, caption}})

    :ok
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
    full = if Path.type(path) == :absolute, do: path, else: Path.join(Workspace.cwd_in_ctx(ctx), path)

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

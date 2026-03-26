# Google Workspace tools for Pepe (Calendar + Gmail), as a drop-in plugin.
#
# These implement the `Pepe.Tools.Tool` behaviour, so `Pepe.Tools.all/0` picks them
# up automatically (no core change). Give an agent any of the tool names below in its
# `tools` list to grant the capability; each call still passes the permission gate.
#
# Auth: Google APIs use OAuth2 bearer tokens. Configure via env vars (the plugin reads
# them at call time, so tokens stay out of the config file):
#
#   * GOOGLE_ACCESS_TOKEN  - a ready access token (simplest; expires in ~1h), OR
#   * GOOGLE_CLIENT_ID + GOOGLE_CLIENT_SECRET + GOOGLE_REFRESH_TOKEN - the plugin mints
#     a fresh access token per call from the refresh token (survives expiry).
#
# The refresh token needs scopes for what you use, e.g.
#   https://www.googleapis.com/auth/calendar
#   https://www.googleapis.com/auth/gmail.modify

defmodule Pepe.Plugins.Google.Auth do
  @moduledoc """
  Resolves a Google OAuth2 bearer token. Reads settings from the plugin's dashboard
  config first (Plugins page -> Configure), falling back to environment variables, so
  it works whether you fill the form or export env vars. Either a ready access token or
  the client-id/secret + refresh-token trio.
  """

  @token_url "https://oauth2.googleapis.com/token"

  @doc "Return `{:ok, bearer}` or `{:error, message}` describing what is missing."
  def token do
    cond do
      t = setting("access_token", "GOOGLE_ACCESS_TOKEN") ->
        {:ok, t}

      setting("refresh_token", "GOOGLE_REFRESH_TOKEN") && setting("client_id", "GOOGLE_CLIENT_ID") &&
          setting("client_secret", "GOOGLE_CLIENT_SECRET") ->
        refresh()

      true ->
        {:error,
         "Google is not configured. Set an access token, or the client id/secret + refresh " <>
           "token, under Plugins -> Configure (or the GOOGLE_* env vars)."}
    end
  end

  defp refresh do
    form = %{
      "client_id" => setting("client_id", "GOOGLE_CLIENT_ID"),
      "client_secret" => setting("client_secret", "GOOGLE_CLIENT_SECRET"),
      "refresh_token" => setting("refresh_token", "GOOGLE_REFRESH_TOKEN"),
      "grant_type" => "refresh_token"
    }

    case Req.post(@token_url, form: form, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"access_token" => t}}} -> {:ok, t}
      {:ok, %{status: s, body: b}} -> {:error, "token refresh failed (#{s}): #{inspect(b)}"}
      {:error, reason} -> {:error, "token refresh error: #{inspect(reason)}"}
    end
  end

  # Prefer the dashboard-entered value (interpolated); fall back to the env var.
  defp setting(key, env_key), do: Pepe.Plugins.config("google", key) || env(env_key)

  defp env(key) do
    case System.get_env(key) do
      nil -> nil
      "" -> nil
      v -> v
    end
  end
end

defmodule Pepe.Plugins.Google.API do
  @moduledoc "Thin Req wrapper that injects the bearer token and normalizes errors."

  alias Pepe.Plugins.Google.Auth

  @doc "Run `fun.(token)` with a resolved bearer token, or short-circuit with its error."
  def with_token(fun) do
    case Auth.token() do
      {:ok, token} -> fun.(token)
      {:error, msg} -> {:error, msg}
    end
  end

  def get(url, token, params \\ []) do
    normalize(Req.get(url, auth: {:bearer, token}, params: params, receive_timeout: 20_000))
  end

  def post(url, token, json) do
    normalize(Req.post(url, auth: {:bearer, token}, json: json, receive_timeout: 20_000))
  end

  defp normalize({:ok, %{status: s, body: body}}) when s in 200..299, do: {:ok, body}
  defp normalize({:ok, %{status: s, body: body}}), do: {:error, "Google API #{s}: #{inspect(body)}"}
  defp normalize({:error, reason}), do: {:error, "request failed: #{inspect(reason)}"}
end

defmodule Pepe.Plugins.GCalUpcoming do
  @moduledoc "List the next few events on the primary Google Calendar."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]
  alias Pepe.Plugins.Google.API

  @impl true
  def name, do: "gcal_upcoming"

  @impl true
  def spec do
    function("gcal_upcoming", "List upcoming events on the user's primary Google Calendar.", %{
      "type" => "object",
      "properties" => %{
        "max" => %{"type" => "integer", "description" => "How many events to return (default 10)."}
      }
    })
  end

  @impl true
  def run(args, _ctx) do
    max = args["max"] || 10
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    API.with_token(fn token ->
      params = [maxResults: max, orderBy: "startTime", singleEvents: true, timeMin: now]

      case API.get("https://www.googleapis.com/calendar/v3/calendars/primary/events", token, params) do
        {:ok, %{"items" => items}} -> {:ok, format_events(items)}
        {:ok, _} -> {:ok, "No upcoming events."}
        error -> error
      end
    end)
  end

  defp format_events([]), do: "No upcoming events."

  defp format_events(items) do
    Enum.map_join(items, "\n", fn e ->
      start = get_in(e, ["start", "dateTime"]) || get_in(e, ["start", "date"]) || "?"
      "#{start}  #{e["summary"] || "(no title)"}"
    end)
  end
end

defmodule Pepe.Plugins.GCalCreateEvent do
  @moduledoc "Create an event on the primary Google Calendar."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]
  alias Pepe.Plugins.Google.API

  @impl true
  def name, do: "gcal_create_event"

  @impl true
  def spec do
    function("gcal_create_event", "Create an event on the user's primary Google Calendar.", %{
      "type" => "object",
      "properties" => %{
        "summary" => %{"type" => "string", "description" => "Event title."},
        "start" => %{"type" => "string", "description" => "Start time, RFC3339 (e.g. 2026-07-10T15:00:00-03:00)."},
        "end" => %{"type" => "string", "description" => "End time, RFC3339."},
        "description" => %{"type" => "string", "description" => "Optional details."}
      },
      "required" => ["summary", "start", "end"]
    })
  end

  @impl true
  def run(%{"summary" => summary, "start" => start_at, "end" => end_at} = args, _ctx) do
    body = %{
      "summary" => summary,
      "description" => args["description"],
      "start" => %{"dateTime" => start_at},
      "end" => %{"dateTime" => end_at}
    }

    API.with_token(fn token ->
      case API.post("https://www.googleapis.com/calendar/v3/calendars/primary/events", token, body) do
        {:ok, %{"htmlLink" => link}} -> {:ok, "Event created: #{link}"}
        {:ok, _} -> {:ok, "Event created."}
        error -> error
      end
    end)
  end

  def run(_, _), do: {:error, "missing required 'summary', 'start' or 'end'"}
end

defmodule Pepe.Plugins.GmailSearch do
  @moduledoc "Search Gmail and return matching messages' sender/subject."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]
  alias Pepe.Plugins.Google.API

  @impl true
  def name, do: "gmail_search"

  @impl true
  def spec do
    function("gmail_search", "Search the user's Gmail and return matching messages (sender + subject).", %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Gmail search query, e.g. 'is:unread from:boss'."},
        "max" => %{"type" => "integer", "description" => "How many messages to return (default 5)."}
      },
      "required" => ["query"]
    })
  end

  @impl true
  def run(%{"query" => query} = args, _ctx) do
    max = args["max"] || 5

    API.with_token(fn token ->
      case API.get("https://gmail.googleapis.com/gmail/v1/users/me/messages", token, q: query, maxResults: max) do
        {:ok, %{"messages" => msgs}} -> {:ok, summarize(msgs, token)}
        {:ok, _} -> {:ok, "No messages match #{inspect(query)}."}
        error -> error
      end
    end)
  end

  def run(_, _), do: {:error, "missing 'query'"}

  defp summarize(msgs, token) do
    msgs
    |> Enum.map(fn %{"id" => id} -> headers(id, token) end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "No readable messages."
      lines -> Enum.join(lines, "\n")
    end
  end

  defp headers(id, token) do
    url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/#{id}"

    case API.get(url, token, format: "metadata", metadataHeaders: ["From", "Subject"]) do
      {:ok, %{"payload" => %{"headers" => hs}}} ->
        "#{header(hs, "From")} — #{header(hs, "Subject")}"

      _ ->
        nil
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, "(none)", fn h -> h["name"] == name && h["value"] end)
  end
end

defmodule Pepe.Plugins.GmailSend do
  @moduledoc "Send a plain-text email from the user's Gmail account."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]
  alias Pepe.Plugins.Google.API

  @impl true
  def name, do: "gmail_send"

  @impl true
  def spec do
    function("gmail_send", "Send a plain-text email from the user's Gmail account.", %{
      "type" => "object",
      "properties" => %{
        "to" => %{"type" => "string", "description" => "Recipient email address."},
        "subject" => %{"type" => "string", "description" => "Subject line."},
        "body" => %{"type" => "string", "description" => "Plain-text body."}
      },
      "required" => ["to", "subject", "body"]
    })
  end

  @impl true
  def run(%{"to" => to, "subject" => subject, "body" => body}, _ctx) do
    raw =
      [
        "To: #{to}",
        "Subject: #{subject}",
        "Content-Type: text/plain; charset=UTF-8",
        "",
        body
      ]
      |> Enum.join("\r\n")
      |> Base.url_encode64(padding: false)

    API.with_token(fn token ->
      case API.post("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", token, %{"raw" => raw}) do
        {:ok, %{"id" => id}} -> {:ok, "Email sent (id #{id})."}
        {:ok, _} -> {:ok, "Email sent."}
        error -> error
      end
    end)
  end

  def run(_, _), do: {:error, "missing 'to', 'subject' or 'body'"}
end

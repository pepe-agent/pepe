defmodule Pepe.Langfuse do
  @cache_ttl 300

  @moduledoc """
  Fetches a prompt managed in Langfuse, for an agent whose `langfuse_prompt` config
  field names one - see `Pepe.Config.Agent`'s field doc and `Pepe.Agent.Workspace`,
  which calls `fetch/1` when building that agent's system prompt.

  Configured the same way every official Langfuse SDK is (so credentials already set
  up for tracing/other tooling just work here too): `LANGFUSE_PUBLIC_KEY`,
  `LANGFUSE_SECRET_KEY`, `LANGFUSE_BASE_URL` (defaults to `https://cloud.langfuse.com`).
  Off (every fetch cleanly misses) unless both keys are set - this is opt-in per
  agent on top of that, never a hard dependency for an install that has no agent
  using it.

  Cached in `Pepe.Store` (see its own moduledoc - the disposable, regenerable tier)
  for #{div(@cache_ttl, 60)} minutes: long enough that a busy agent isn't fetching
  on every single turn, short enough that an edit in Langfuse reaches a running
  Pepe within a few minutes with no restart.
  """

  @cache_ns :langfuse_prompt

  @doc "Are Langfuse credentials configured at all? Checked before every fetch attempt."
  @spec enabled? :: boolean()
  def enabled?, do: public_key() not in [nil, ""] and secret_key() not in [nil, ""]

  @doc """
  Fetch a prompt by name, cached. Returns `{:ok, text}` or `{:error, reason}` - a
  caller (`Pepe.Agent.Workspace`) always has a local fallback for the error case,
  so this never needs to raise or block on retry logic of its own.
  """
  @spec fetch(String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch(name) when is_binary(name) and name != "" do
    if enabled?() do
      case Pepe.Store.get(@cache_ns, name) do
        nil -> fetch_and_cache(name)
        text -> {:ok, text}
      end
    else
      {:error, :not_configured}
    end
  end

  def fetch(_), do: {:error, :no_prompt_name}

  defp fetch_and_cache(name) do
    case do_fetch(name) do
      {:ok, text} ->
        Pepe.Store.put(@cache_ns, name, text, ttl: @cache_ttl)
        {:ok, text}

      error ->
        error
    end
  end

  defp do_fetch(name) do
    Req.get(url(name),
      auth: {:basic, "#{public_key()}:#{secret_key()}"},
      receive_timeout: 8_000,
      retry: false
    )
    |> case do
      {:ok, %{status: 200, body: body}} -> extract_text(body)
      {:ok, %{status: 404}} -> {:error, {:not_found, name}}
      {:ok, %{status: s}} -> {:error, {:http_status, s}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # https://langfuse.com/docs/prompt-management - a "text" prompt's template is a
  # plain string, which is exactly what an agent's system_prompt is; a "chat" prompt
  # is an array of role/content messages, so the closest sane mapping onto a single
  # persona string is the system-role message if there is one, else the first one.
  defp extract_text(%{"type" => "text", "prompt" => text}) when is_binary(text), do: {:ok, text}

  defp extract_text(%{"type" => "chat", "prompt" => messages}) when is_list(messages) do
    case Enum.find(messages, &(&1["role"] == "system")) || List.first(messages) do
      %{"content" => content} when is_binary(content) -> {:ok, content}
      _ -> {:error, :empty_chat_prompt}
    end
  end

  defp extract_text(_), do: {:error, :unrecognized_response}

  defp url(name), do: "#{base_url()}/api/public/v2/prompts/#{URI.encode(name)}"

  defp base_url, do: (System.get_env("LANGFUSE_BASE_URL") || "https://cloud.langfuse.com") |> String.trim_trailing("/")
  defp public_key, do: System.get_env("LANGFUSE_PUBLIC_KEY")
  defp secret_key, do: System.get_env("LANGFUSE_SECRET_KEY")
end

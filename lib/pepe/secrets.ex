defmodule Pepe.Secrets do
  @moduledoc """
  Recognising a credential that was written down in the clear.

  ## Why nothing here refuses anything

  Pepe used to refuse to save an MCP server when it spotted a raw-looking token in the
  arguments. That felt responsible and was close to useless, because of *when* it happened:
  by then the token had already been typed into a chat. It had gone to a model provider, it
  was sitting in the conversation, and it was in the trace on disk. The refusal did not
  un-leak it. It only meant the server did not get added, the person did not understand why,
  and the next thing they did was paste the token somewhere else.

  A leaked secret is leaked. What is left to do is tell the truth about it, loudly, and
  make the fix easy: **the token is burned, revoke it, reissue it, and put the new one in an
  environment variable.** So the write goes through, and the answer says so.

  It also means the same recognition has to run in `pepe doctor`, because that is what
  catches the ones nobody read the warning for. One module, so the tool and the diagnostic
  cannot disagree about what a secret looks like.
  """

  # A key whose *name* says it holds a credential. Matched on word parts, so `GITHUB_TOKEN`
  # and `BRAVE_API_KEY` are caught while `monkey` and `model` are not - a check that fires on
  # the wrong things gets ignored, and then it protects nothing.
  @secret_words ~w(token key secret password passwd pwd credential credentials apikey pat auth)

  # Keys that are secrets by whole name, even without a word part above.
  @secret_names ~w(api_key bot_token app_secret client_secret verify_token access_token refresh_token signing_secret)

  @doc """
  Does this key name say it holds a credential?

      iex> Pepe.Secrets.secret_key?("GITHUB_TOKEN")
      true
      iex> Pepe.Secrets.secret_key?("BRAVE_API_KEY")
      true
      iex> Pepe.Secrets.secret_key?("monkey")
      false
  """
  @spec secret_key?(String.t() | atom()) :: boolean()
  def secret_key?(key) do
    name = key |> to_string() |> String.downcase()

    name in @secret_names or
      name |> String.split(~r/[_\-.\s]+/, trim: true) |> Enum.any?(&(&1 in @secret_words))
  end

  @doc """
  Is this value a credential someone typed in, rather than a reference to one?

  A `${ENV_VAR}` reference is exactly what we want people to write, so it is never a finding.
  Everything else long and credential-shaped is.
  """
  @spec plaintext?(term()) :: boolean()
  def plaintext?(value) when is_binary(value) do
    value != "" and not reference?(value) and credential_shaped?(value)
  end

  def plaintext?(_value), do: false

  @doc "A `${ENV_VAR}` reference: the thing we are asking people to write."
  @spec reference?(String.t()) :: boolean()
  def reference?(value) when is_binary(value), do: String.contains?(value, "${")
  def reference?(_value), do: false

  # Either it announces itself (a known provider prefix), or it is a long opaque run of the
  # characters credentials are made of. Short values are left alone: "true", a port, a model
  # name. We would rather miss a short token than cry wolf on every setting in the file.
  defp credential_shaped?(value) do
    Regex.match?(~r/^(sk-|xox[baprs]-|ghp_|gho_|ghu_|ghs_|github_pat_|glpat-|AIza|hf_|pk-|Bearer\s)/i, value) or
      (String.length(value) >= 24 and Regex.match?(~r/^[A-Za-z0-9_\-\.\/\+=]{24,}$/, value))
  end

  @doc """
  Any credential typed in the clear inside `map` (values, and any nested map), as
  `[{key, value}]`. Used both to warn at write time and to find them again later.
  """
  @spec plaintext_in(map()) :: [{String.t(), String.t()}]
  def plaintext_in(map) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      cond do
        is_map(v) -> plaintext_in(v)
        plaintext?(v) -> [{to_string(k), v}]
        true -> []
      end
    end)
  end

  def plaintext_in(_map), do: []

  @doc """
  Show a credential without printing it: enough to recognise which one it is, not enough to
  use it. A warning that reprints the secret has copied it somewhere new.
  """
  @spec mask(String.t()) :: String.t()
  def mask(value) when is_binary(value) do
    case String.length(value) do
      n when n <= 8 -> String.duplicate("*", n)
      n -> String.slice(value, 0, 4) <> String.duplicate("*", min(n - 8, 12)) <> String.slice(value, -4, 4)
    end
  end

  @doc """
  What to tell someone who has just written a credential into the clear.

  It has to say the uncomfortable part, because the uncomfortable part is the actionable one:
  the token did not merely land in a file, it went through a model provider on the way and is
  in the transcript. Rotating it is not being careful, it is the only thing that works.
  """
  @spec warning([{String.t(), String.t()}], String.t()) :: String.t()
  def warning([], _where), do: ""

  def warning(found, where) do
    which = Enum.map_join(found, ", ", fn {k, v} -> "#{k} (#{mask(v)})" end)

    """

    ⚠️  A secret was written in the clear: #{which}, in #{where}.

    Tell the user, plainly, that:
      1. **That token must be revoked and reissued.** It was typed into a chat, so it has \
    already been sent to the model provider and is in this conversation and in the trace on \
    disk. It is compromised now, whatever we do next. Rotating it is the only thing that \
    actually fixes that.
      2. The new one should never be pasted here. It goes in an environment variable, and \
    the config refers to it: set `#{elem(hd(found), 0)}` in the environment (the shell, the \
    systemd unit, or `environment:` in docker-compose.yml), and write `${#{elem(hd(found), 0)}}` \
    in the config instead of the value.
      3. Once the new one is in the environment, this entry should be changed to the \
    `${...}` form.

    Say it once, clearly, without lecturing. Then carry on with what they asked for.
    """
  end
end

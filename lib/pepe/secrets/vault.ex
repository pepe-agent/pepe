defmodule Pepe.Secrets.Vault do
  @moduledoc """
  Fetch a secret from wherever you actually keep it, at the moment it is needed.

  An environment variable is a fine place for a secret and a poor place for a *secret you
  care about*. It sits there in the clear for the life of the process, you change it by
  logging into the server and restarting, and nothing anywhere records who could read it.

  So a config value may also say **where the secret lives** instead of what it is:

      "api_key": "exec:<any command that prints the secret>"
      "api_key": "file:/run/secrets/openai_key"

  The contract is the whole design, and it is one sentence: **a command that prints the
  secret on stdout**. Nothing in this module knows what a vault is, which vaults exist, or
  what any of them are called. It runs what you wrote and takes what comes back.

  That is why every vault works, including the ones nobody has heard of and the one you wrote
  yourself. A few, purely as illustrations of the shape - none of them is special, none is
  hard-coded, and none of them appears anywhere in this code:

      exec:op read op://Work/openai/key
      exec:vault kv get -field=key secret/openai
      exec:aws secretsmanager get-secret-value --secret-id openai --query SecretString --output text
      exec:security find-generic-password -w -s openai
      exec:gcloud secrets versions access latest --secret=openai
      exec:pass show openai/key
      exec:cat /etc/my-own-script-output

  ## Why this is not the agent running `op read`

  An agent *can* be told to fetch its own secrets with the shell, and it will. The value then
  comes back as a tool result, which means it has been read by the model, sent to a model
  provider, and written into the transcript and the trace. The vault kept it safe right up
  until the moment it was used, and then it was handed to the least trustworthy component in
  the system.

  Here, the command is run by the **runtime**, at the point of use - as the HTTP request to
  the provider is being built. The value never enters a tool result, a message, or a context
  window. The agent asks for the conversation; it never asks for the key.

  ## The cache, and why it has to exist

  Opening a vault costs a few hundred milliseconds, and a busy Pepe resolves the same key on
  every model call. Values are cached in memory, per exact reference, for #{div(60_000, 1000)}
  seconds. That does mean a resolved secret lives in this process's memory for up to a minute,
  which is a real cost and worth saying plainly: this reduces the window, it does not abolish
  it. Rotating a secret in the vault takes effect within the TTL, with no restart.
  """

  use GenServer

  require Logger

  @table :pepe_secret_cache
  @ttl_ms 60_000
  @timeout_ms 15_000

  @exec_ref "exec:"
  @file_ref "file:"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Whether this config value points at a vault rather than holding a secret."
  @spec ref?(term()) :: boolean()
  def ref?(value) when is_binary(value),
    do: String.starts_with?(value, @exec_ref) or String.starts_with?(value, @file_ref)

  def ref?(_value), do: false

  @doc """
  Resolve a reference to the secret it points at, or `nil` when it cannot be fetched.

  Never raises and never returns a partial value: a vault that is locked, missing, or slow
  yields `nil`, and the caller then behaves exactly as it does for an unset environment
  variable. A wrong secret would be worse than no secret - it would be an authentication
  failure nobody could explain.
  """
  @spec resolve(String.t()) :: String.t() | nil
  def resolve(@exec_ref <> command), do: cached("e:" <> command, fn -> run(command) end)
  def resolve(@file_ref <> path), do: cached("f:" <> path, fn -> read(path) end)
  def resolve(_value), do: nil

  @doc "Forget every cached secret (on rotation, or when you simply want them gone)."
  def flush do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  ###
  ### the cache
  ###

  defp cached(key, fun) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, expires}] when expires > now ->
        value

      _ ->
        case fun.() do
          nil ->
            # A failure is not cached: the vault may simply have been locked for a moment, and
            # caching "no" would keep Pepe broken long after the human unlocked it.
            nil

          value ->
            :ets.insert(@table, {key, value, now + @ttl_ms})
            value
        end
    end
  end

  ###
  ### the backends
  ###

  # A near-empty environment: enough for a command to find itself and reach a local agent
  # socket, and nothing more. A resolver fetching one secret has no business being handed
  # Pepe's others on the way past. Anything a particular vault needs beyond this is named by
  # the operator in `secrets.vault_env` - Pepe does not know, and does not want to know, what
  # those variables mean.
  @pass_env ~w(HOME PATH USER LANG TERM SSH_AUTH_SOCK)

  defp run(command) do
    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command], env: resolver_env(), stderr_to_stdout: false)
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> presence(String.trim(out))
      {:ok, {_out, status}} -> warn("returned #{status}", command)
      nil -> warn("took longer than #{div(@timeout_ms, 1000)}s", command)
    end
  rescue
    e -> warn(Exception.message(e), command)
  end

  # What the resolver is allowed to see: `@pass_env`, plus the variables the operator declared
  # their vault needs (a service-account token, a vault address, a profile name - whatever
  # theirs happens to want; Pepe passes them through without knowing what any of them mean,
  # which is what keeps this generic). Everything else is removed by name.
  #
  # Removed by *name*, because `System.cmd/3` merges `:env` into the parent's environment
  # rather than replacing it. Listing what to keep keeps everything, which is a control that
  # looks like it works - the reason the test below asks a real resolver what it can see.
  defp resolver_env do
    allowed = MapSet.new(@pass_env ++ Pepe.Config.vault_env())

    System.get_env()
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(allowed, &1))
    |> Enum.map(&{&1, nil})
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> presence(String.trim(contents))
      {:error, reason} -> warn(:file.format_error(reason) |> to_string(), path)
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  # The command, never its output. A log line that helpfully prints what the vault returned
  # has taken a secret out of the vault and put it in a file that gets shipped to a log server.
  defp warn(why, what) do
    Logger.warning("[secrets] could not resolve #{inspect(what)}: #{why}")
    nil
  end

  ###
  ### GenServer (owns the table for the node's lifetime)
  ###

  @impl true
  def init(:ok) do
    ensure_table()
    {:ok, %{}}
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end

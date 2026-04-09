defmodule Pepe.ModelSwitch do
  @moduledoc """
  Shared logic behind the `/model` and `/models` chat commands, channel-agnostic -
  every gateway (Telegram, the generic webhook channels, the dashboard chat) calls
  into this instead of reimplementing filtering/permission/apply. No text
  formatting or gettext here; each gateway renders its own message.

  Three pieces:

    * `list_for/1` - the models a caller may see, scoped to their company.
    * `permission/2` - what a caller may do: change the model for everyone
      (`:global`), just their own conversation (`:session`), or nothing (`:none`).
    * `apply/4` - actually make the change at the given scope.

  `:global` is reserved for **trainers** (the same allowlist that already gates
  `/learn`/memory) - there is no separate "who can switch models" list. Everyone
  else in an allowed chat gets `:session` unless the connection sets a
  `model_switch_locked` flag, which drops them to `:none`.
  """

  alias Pepe.Agent.Session
  alias Pepe.Company
  alias Pepe.Config

  @doc "Models visible to `company` (`nil` = the root scope), sorted by name."
  @spec list_for(String.t() | nil) :: [Config.Model.t()]
  def list_for(company) do
    Config.models()
    |> Enum.filter(&(Company.of(&1.name) == company))
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  What a caller may do with `/model`: `:global` (trainer - may change it for
  everyone, or just their session), `:session` (may only change their own),
  or `:none` (model-switching is off for them on this connection).
  """
  @spec permission(boolean(), boolean()) :: :global | :session | :none
  def permission(trainer?, locked?) do
    cond do
      trainer? -> :global
      locked? -> :none
      true -> :session
    end
  end

  @doc """
  Apply a model change. `:session` sets an in-memory override on that session
  only (`Pepe.Agent.Session.set_model/2`, never touches `Pepe.Config`); `:global`
  persists it on the agent definition, same as any other config edit. Returns
  `:ok` or `{:error, :unknown_model}` / `{:error, :unknown_agent}`.
  """
  @spec apply(String.t(), String.t(), String.t(), :session | :global) ::
          :ok | {:error, :unknown_model | :unknown_agent}
  def apply(session_key, _agent_name, model_name, :session) do
    if Config.get_model(model_name) do
      Session.set_model(session_key, model_name)
      :ok
    else
      {:error, :unknown_model}
    end
  end

  def apply(_session_key, agent_name, model_name, :global) do
    cond do
      is_nil(Config.get_model(model_name)) ->
        {:error, :unknown_model}

      is_nil(Config.get_agent(agent_name)) ->
        {:error, :unknown_agent}

      true ->
        agent = Config.get_agent(agent_name)
        Config.put_agent(%{agent | model: model_name})
        :ok
    end
  end
end

defmodule Pepe.ACP.Auth do
  @moduledoc """
  The authentication half of the ACP handshake.

  There is nothing to log *in* to: Pepe talks to model providers with the connections
  in its own configuration, and no editor has a token to hand over. What an editor does
  need to know is whether this agent can answer at all, because the alternative is a
  connection that opens fine and then fails on the first message with a stack of
  provider errors. So the two auth methods advertised are really two answers to "is
  Pepe configured yet?":

    * `pepe-config` (present only once it is true): use the model connections already
      in Pepe's configuration. Selecting it succeeds while the bound agent still has a
      usable model, and fails with the reason when it does not.
    * `pepe-setup`, always present: a *terminal* method. The editor runs the same
      command line it started the agent with, plus `--setup`, in a terminal it opens
      for the person - `pepe acp --setup` - which runs Pepe's interactive setup and
      exits. Picking it succeeds once that has produced a usable model.

  `session/new` on an agent with no usable model fails with `auth_required` (ACP's
  `-32000`) instead, which is the code that makes an editor offer these methods.
  """

  alias Pepe.Config

  @config_id "pepe-config"
  @setup_id "pepe-setup"

  # ACP's reserved "the agent needs authenticating first" JSON-RPC code.
  @auth_required -32_000

  @doc "The `authMethods` advertised in `initialize` for the agent this connection is bound to."
  @spec methods(String.t() | nil) :: [map()]
  def methods(agent_name) do
    setup = %{
      "id" => @setup_id,
      "name" => "Set up Pepe",
      "description" => "Open Pepe's interactive setup in a terminal to add a model connection.",
      "type" => "terminal",
      "args" => ["--setup"]
    }

    if ready?(agent_name) do
      [
        %{
          "id" => @config_id,
          "name" => "Pepe configuration",
          "description" => "Use the model connections already configured in Pepe."
        },
        setup
      ]
    else
      [setup]
    end
  end

  @doc """
  `authenticate`: `{:ok, %{}}` when the method is one we advertised and the agent can now
  answer, `{:error, reason}` (a human-readable string) when it cannot, `:unknown_method`
  for an id we never offered.
  """
  @spec authenticate(term(), String.t() | nil) :: {:ok, map()} | {:error, String.t()} | :unknown_method
  def authenticate(method_id, agent_name) when method_id in [@config_id, @setup_id] do
    case check(agent_name) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  def authenticate(_method_id, _agent_name), do: :unknown_method

  @doc "Whether the bound agent has a model connection it can actually send to."
  @spec ready?(String.t() | nil) :: boolean()
  def ready?(agent_name), do: check(agent_name) == :ok

  @doc """
  Why the agent cannot answer, or `:ok`. The message names the fix in Pepe's own
  vocabulary, because it is shown to a person looking at an editor, not at a log.
  """
  @spec check(String.t() | nil) :: :ok | {:error, String.t()}
  def check(agent_name) do
    case Pepe.Agent.resolve(agent_name) do
      {:error, :no_agent_configured} ->
        {:error, "Pepe has no agent yet. Run `pepe setup` (or pick this method to open it), then try again."}

      {:error, {:unknown_agent, name}} ->
        {:error,
         "Pepe has no agent named `#{name}`. Create it with `pepe agent add`, or start the editor connection without a name for the default one."}

      {:ok, agent} ->
        case Config.model_for_agent(agent) do
          %{model: model, base_url: url} when is_binary(model) and model != "" and is_binary(url) and url != "" ->
            :ok

          _ ->
            {:error, "Agent `#{agent.name}` has no usable model connection. Add one with `pepe model add`, or run `pepe setup`."}
        end
    end
  end

  @doc "The JSON-RPC error code for \"authenticate first\"."
  @spec auth_required_code() :: integer()
  def auth_required_code, do: @auth_required
end

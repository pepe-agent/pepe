defmodule Pepe.ACP.Settings do
  @moduledoc """
  The two things an editor lets a person change about a running session without leaving
  the chat panel: which model answers, and how much the agent may do without asking.

  ACP describes them twice, and a client uses whichever generation it understands - the
  older `models` / `modes` objects and the newer `configOptions` list - so this module
  builds all three from one place and `Pepe.ACP.Server` merges them into every session
  response (`session_fields/3`).

  ## Models

  The model choices are the connections `Pepe.ModelSwitch.list_for/1` already offers on
  every other surface, scoped to the agent's project, and choosing one is the same
  per-conversation switch `/model NAME` makes (`Pepe.ModelSwitch.apply/4` with the
  `:session` scope): nothing is written to the configuration, and the choice ends with
  the conversation. Changing the model for everyone stays a deliberate act
  (`/model NAME global`, or the configuration itself), not something a dropdown does.

  ## Modes

  Modes are an *edit approval policy*, and only that (see `Pepe.ACP.Edits`):

    * `default` - ask before changing files, as ever.
    * `accept_edits` - edits inside the project the editor has open (or the temp
      directory) go through without a prompt; anything else still asks.
    * `dont_ask` - edits anywhere go through without a prompt.

  Every mode still asks about a sensitive path, about a call a policy plugin escalated,
  and about anything once the run has taken in outside content, and no mode touches
  what commands or the network may do. That is why there is no "allow everything" mode:
  the permission prompt already offers that, scoped to a task or a session, at the moment
  a person can see what it covers.
  """

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.ModelSwitch
  alias Pepe.Project

  @default_mode "default"

  @modes [
    {"default", "Default", "Ask before changing files."},
    {"accept_edits", "Accept edits", "Edit files in this project without asking; ask about anything else."},
    {"dont_ask", "Don't ask", "Edit files anywhere without asking, except sensitive paths."}
  ]

  @doc "The mode a new session starts in."
  @spec default_mode() :: String.t()
  def default_mode, do: @default_mode

  @doc "Whether `mode_id` names a mode."
  @spec mode?(term()) :: boolean()
  def mode?(mode_id), do: Enum.any?(@modes, fn {id, _, _} -> id == mode_id end)

  @doc """
  The `models`, `modes` and `configOptions` fields for a session response, for a session
  keyed `key` bound to `agent_name` and currently in `mode`.
  """
  @spec session_fields(String.t(), String.t() | nil, String.t()) :: map()
  def session_fields(key, agent_name, mode) do
    models = model_choices(agent_name)
    current = current_model(key, agent_name)

    fields = %{
      "modes" => %{
        "currentModeId" => mode,
        "availableModes" => Enum.map(@modes, fn {id, name, desc} -> %{"id" => id, "name" => name, "description" => desc} end)
      },
      "configOptions" => build_options(models, current, mode)
    }

    if models == [] do
      fields
    else
      Map.put(fields, "models", %{
        "currentModelId" => current || "",
        "availableModels" => Enum.map(models, fn m -> %{"modelId" => m.name, "name" => m.name, "description" => m.model} end)
      })
    end
  end

  @doc "The `configOptions` list alone (the response to `session/set_config_option`)."
  @spec config_options(String.t(), String.t() | nil, String.t()) :: [map()]
  def config_options(key, agent_name, mode),
    do: build_options(model_choices(agent_name), current_model(key, agent_name), mode)

  defp build_options(models, current, mode) do
    mode_option = %{
      "id" => "mode",
      "name" => "Mode",
      "description" => "How much the agent may do to your files without asking.",
      "category" => "mode",
      "type" => "select",
      "currentValue" => mode,
      "options" => Enum.map(@modes, fn {id, name, desc} -> %{"value" => id, "name" => name, "description" => desc} end)
    }

    case models do
      [] ->
        [mode_option]

      models ->
        [
          %{
            "id" => "model",
            "name" => "Model",
            "description" => "The model that answers in this conversation.",
            "category" => "model",
            "type" => "select",
            "currentValue" => current || hd(models).name,
            "options" => Enum.map(models, fn m -> %{"value" => m.name, "name" => m.name, "description" => m.model} end)
          },
          mode_option
        ]
    end
  end

  @doc """
  Switch the model for this conversation only. `:ok`, or `{:error, message}` for a name
  that isn't one of the choices offered.
  """
  @spec set_model(String.t(), String.t() | nil, term()) :: :ok | {:error, String.t()}
  def set_model(key, agent_name, model_id) when is_binary(model_id) do
    if Enum.any?(model_choices(agent_name), &(&1.name == model_id)) do
      # The switch is a call to the session process, which a new editor session doesn't
      # have until its first message; start it so a choice made before typing sticks.
      {:ok, _pid} = SessionSupervisor.ensure(key, agent_name)

      case ModelSwitch.apply(key, agent_name, model_id, :session) do
        :ok -> :ok
        {:error, _} -> {:error, "unknown model `#{model_id}`"}
      end
    else
      {:error, "unknown model `#{model_id}` (see the choices reported when the session was created)"}
    end
  end

  def set_model(_key, _agent_name, _other), do: {:error, "`modelId` must be a string"}

  defp model_choices(agent_name) do
    project =
      case Pepe.Agent.resolve(agent_name) do
        {:ok, agent} -> Project.of(agent.name)
        _ -> nil
      end

    ModelSwitch.list_for(project)
  end

  # The connection name in force for the conversation. A session process is only started
  # by its first message or command, so before that the answer is the agent's own model.
  defp current_model(key, agent_name) do
    case live_model(key) do
      nil -> agent_model(agent_name)
      name -> name
    end
  end

  defp live_model(key) do
    Session.model_name(key)
  catch
    :exit, _ -> nil
  end

  defp agent_model(agent_name) do
    with {:ok, agent} <- Pepe.Agent.resolve(agent_name),
         %{name: name} <- Pepe.Config.model_for_agent(agent) do
      name
    else
      _ -> nil
    end
  end
end

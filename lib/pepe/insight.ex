defmodule Pepe.Insight do
  @moduledoc """
  Local predictive models over an operator's own data: define what to predict (a spec -
  target column, feature columns, and where the rows come from), train a small model over
  verified/observed outcomes, and query it for cheap local predictions afterward instead of
  reasoning from scratch every time. Every model has one fixed target column and only gets
  better as more real examples of that specific outcome accumulate - bounded supervised
  learning, not open-ended self-improvement.

  Rows come from either a registered Postgres connection (`source_kind: "db"`, via the same
  tenant-scoped path `db_query` uses - RLS is inherited, never bypassed - see
  `Pepe.Insight.Source`) or previously imported rows (`source_kind: "import"`, fed by
  `insight import_rows` - the path any data source reachable via `bash` + a database CLI
  goes through, since Pepe deliberately does not build native multi-engine DB support here;
  see the `sql-databases` skill). `Pepe.Insight.Source` is the only place that knows which
  kind a spec is; `Trainer`/`Predictor` never branch on it.

  The schema is internal - every public function here takes/returns a bare string-keyed
  map, same boundary convention as `Pepe.Graph`.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Pepe.Config
  alias Pepe.Insight.Examples
  alias Pepe.Insight.Model
  alias Pepe.Insight.Predictor
  alias Pepe.Insight.Spec
  alias Pepe.Insight.Trainer
  alias Pepe.Repo

  @task_types ~w(classification regression clustering forecast)
  # An explicit override of Pepe.Insight.Trainer's automatic, volume-based algorithm
  # choice - "linear" | "gbm" | "neural" | nil (the default: auto-picked). Never required;
  # exists for an operator with the technical background to know exactly which family they
  # want instead of letting data volume decide.
  @families ~w(linear gbm neural)
  # \A...\z (not ^...$) - the latter's $ matches before a trailing newline too, so
  # "users\n" would otherwise pass as a valid identifier.
  @identifier ~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/

  ###
  ### specs
  ###

  @doc "Every spec for one agent, sorted by name."
  @spec list_specs(String.t()) :: [map()]
  def list_specs(agent_ref) do
    case canonical_agent(agent_ref) do
      nil -> []
      agent -> from(s in Spec, where: s.agent == ^agent, order_by: s.name) |> Repo.all() |> Enum.map(&to_map/1)
    end
  end

  @doc "Fetch one spec by agent + name, or nil."
  @spec get_spec(String.t(), String.t()) :: map() | nil
  def get_spec(agent_ref, name) do
    case fetch_struct(agent_ref, name) do
      nil -> nil
      spec -> to_map(spec)
    end
  end

  @doc "Full spec plus every trained model version, newest first."
  @spec describe(String.t(), String.t()) :: map() | nil
  def describe(agent_ref, name) do
    case fetch_struct(agent_ref, name) do
      nil -> nil
      spec -> Map.put(to_map(spec), "models", models_for(spec.id))
    end
  end

  @doc "Delete a spec, its model history, and any imported examples."
  @spec delete_spec(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete_spec(agent_ref, name) do
    case fetch_struct(agent_ref, name) do
      nil ->
        {:error, :not_found}

      spec ->
        Repo.transaction(fn ->
          from(m in Model, where: m.spec_id == ^spec.id) |> Repo.delete_all()
          from(e in Examples, where: e.spec_id == ^spec.id) |> Repo.delete_all()
          Repo.delete!(spec)
        end)

        :ok
    end
  end

  @doc """
  Validate and persist a spec (upsert on `[agent, name]`). `attrs` is a string-keyed map:
  `"agent"`, `"name"`, `"target_column"`, `"feature_columns"` (array of identifiers),
  `"source"` - `%{"kind" => "db", "connection" => ..., "table" => ...}` or `%{"kind" =>
  "import"}` - and optionally `"task_type"` (default `"classification"`),
  `"retrain_interval_s"`, `"min_new_rows"` (default 50), `"mode"` (default `"manual"`).
  """
  @spec define_spec(map()) :: {:ok, map()} | {:error, {:invalid, [String.t()]}}
  def define_spec(attrs) do
    case Config.get_agent(attrs["agent"]) do
      nil ->
        {:error, {:invalid, ["unknown agent #{inspect(attrs["agent"])}"]}}

      agent ->
        case validate(attrs) do
          [] -> {:ok, save(agent.name, attrs)}
          errors -> {:error, {:invalid, errors}}
        end
    end
  end

  @doc "Import rows into an `\"import\"` spec. See `Pepe.Insight.Examples.import/3`."
  @spec import_rows(String.t(), String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def import_rows(agent_ref, name, rows, opts \\ []) do
    case fetch_struct(agent_ref, name) do
      nil -> {:error, :not_found}
      %Spec{source_kind: "import"} = spec -> Examples.import(spec, rows, opts)
      %Spec{} -> {:error, "#{name} is a \"db\" spec - import_rows only applies to \"import\" specs"}
    end
  end

  ###
  ### training / prediction
  ###

  @doc "Train (or retrain) `name` now, synchronously. Persists the new model version and updates the spec's status."
  @spec train_now(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def train_now(agent_ref, name, ctx \\ %{}) do
    case fetch_struct(agent_ref, name) do
      nil -> {:error, :not_found}
      spec -> run_train(spec, ctx)
    end
  end

  @doc "Predict from `name`'s current *ready* model. `input` maps feature column -> value."
  @spec predict(String.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def predict(agent_ref, name, input) do
    case fetch_struct(agent_ref, name) do
      nil ->
        {:error, :not_found}

      %Spec{status: "ready"} = spec ->
        case latest_model(spec.id) do
          nil -> {:error, "no trained model yet for #{name} - call train_now first"}
          model -> Predictor.predict(model, input)
        end

      # Anything but "ready" (pending/training/failed, or reset back to "pending" by a
      # redefine that changed the spec's shape - see save/2) means the newest model, if any,
      # no longer reflects the spec's current target/features - answering from it anyway
      # would be a silent wrong answer, not a stale-but-honest one.
      %Spec{status: status} ->
        {:error, "#{name} is not ready to predict (status: #{status}) - call train_now first"}
    end
  end

  @doc "The newest trained model for a spec id, or nil."
  @spec latest_model(String.t()) :: Model.t() | nil
  def latest_model(spec_id) do
    from(m in Model, where: m.spec_id == ^spec_id, order_by: [desc: m.version], limit: 1) |> Repo.one()
  end

  @doc """
  Every spec with `retrain_interval_s` set whose interval has elapsed since
  `last_trained_at` (or `created_at`, if it has never trained) - the candidates
  `Pepe.Insight.Scheduler` checks each tick, before the (cheaper) row-count gate that
  decides whether a fit actually runs.
  """
  @spec due_specs(integer()) :: [Spec.t()]
  def due_specs(now) do
    from(s in Spec, where: not is_nil(s.retrain_interval_s)) |> Repo.all() |> Enum.filter(&due?(&1, now))
  end

  defp due?(%Spec{retrain_interval_s: interval, last_trained_at: last, created_at: created}, now) do
    now - (last || created) >= interval
  end

  @doc """
  Mark every spec still "training" as failed - meant to run once at boot. A "training"
  marker can only be stale by the time the app starts fresh: the run that set it either
  finished (and moved the status on) or was interrupted by a kill/crash/restart, since
  nothing else ever holds that status across a process lifetime.
  """
  @spec reconcile_stuck_training() :: :ok
  def reconcile_stuck_training do
    from(s in Spec, where: s.status == "training")
    |> Repo.update_all(set: [status: "failed", last_error: "interrupted by restart", updated_at: System.system_time(:second)])

    :ok
  end

  defp run_train(spec, ctx) do
    case claim_training(spec.id) do
      # A scheduled retrain and a conversational train_now can race for the same spec - the
      # loser here bails out immediately instead of also fitting (wasted work) and then
      # losing a unique_index race on the model version, which used to mark a spec "failed"
      # even when the winner's training genuinely succeeded.
      :already_training ->
        {:error, :already_training}

      :ok ->
        do_train(spec, ctx)
    end
  end

  defp claim_training(spec_id) do
    {count, _} =
      from(s in Spec, where: s.id == ^spec_id and s.status != "training")
      |> Repo.update_all(set: [status: "training", last_error: nil, updated_at: System.system_time(:second)])

    if count == 1, do: :ok, else: :already_training
  end

  defp do_train(spec, ctx) do
    started_at = System.monotonic_time(:millisecond)
    Logger.info("insight #{spec.id} (#{spec.agent}/#{spec.name}): training started")

    case Trainer.train(spec, ctx) do
      {:ok, result} ->
        Logger.info(
          "insight #{spec.id}: training succeeded (#{result.algorithm}, #{result.metric_name}=#{result.metric_value}) in #{System.monotonic_time(:millisecond) - started_at}ms"
        )

        persist_trained(spec, result)

      {:error, reason} ->
        Logger.warning("insight #{spec.id}: training failed: #{to_string_reason(reason)}")
        mark_status(spec.id, "failed", to_string_reason(reason))
        {:error, reason}
    end
  rescue
    # A fit can raise (a degenerate NaN metric, a malformed row Trainer's own checks didn't
    # catch, ...) - without this, the spec is left stuck at status "training" forever, since
    # nothing ever reverts it. Re-raising after marking keeps the original crash visible
    # (logged, surfaced to the caller) while guaranteeing the spec's own state never lies.
    e ->
      Logger.error("insight #{spec.id}: training crashed: #{Exception.message(e)}")
      mark_status(spec.id, "failed", "crashed while training: #{Exception.message(e)}")
      reraise e, __STACKTRACE__
  end

  # Kept per spec, newest first - unlike insight_examples (a spec's accumulated training
  # data, meant to grow), a model version is a full trained artifact and every algorithm
  # here produces a fresh one on each retrain. Nothing without this would ever remove one.
  @model_retention 5

  defp persist_trained(spec, result) do
    now = System.system_time(:second)
    version = next_version(spec.id)

    Repo.insert!(%Model{
      id: new_model_id(),
      spec_id: spec.id,
      version: version,
      algorithm: result.algorithm,
      task_type: result.task_type,
      feature_columns: Map.get(result, :model_feature_columns, spec.feature_columns),
      sample_count: result.sample_count,
      metric_name: result.metric_name,
      metric_value: result.metric_value,
      params: params_for(result),
      artifact: serialize_artifact(result.algorithm, result.model),
      trained_at: now,
      created_at: now
    })

    prune_models(spec.id)

    # row_count_at_last_train is compared against a fresh population count on the next
    # retrain check (see Pepe.Insight.Scheduler) - it must be the source's actual row count,
    # never result.sample_count (which is capped by Source's sampling limits and, for
    # clustering, further subsampled). Recording the sample size there would make a spec
    # whose source is larger than the sample cap look "still has new rows" forever, forcing
    # a full re-fetch (and, for a "db" spec between the sample cap and 3x it, a full
    # table scan+sort) on every elapsed interval even with zero genuinely new rows.
    from(s in Spec, where: s.id == ^spec.id)
    |> Repo.update_all(
      set: [status: "ready", last_error: nil, last_trained_at: now, row_count_at_last_train: result.population, updated_at: now]
    )

    {:ok,
     %{"version" => version, "algorithm" => result.algorithm, "metric_name" => result.metric_name, "metric_value" => result.metric_value}}
  end

  # "classes" only means something for classification - leaving it out entirely for
  # regression/forecast/kmeans (rather than storing an always-nil key) keeps params free of
  # a field that never applies to those task types.
  defp params_for(%{classes: nil} = result), do: Map.get(result, :extra_params, %{})
  defp params_for(result), do: Map.merge(%{"classes" => result.classes}, Map.get(result, :extra_params, %{}))

  defp prune_models(spec_id) do
    keep_ids =
      from(m in Model, where: m.spec_id == ^spec_id, order_by: [desc: m.version], limit: @model_retention, select: m.id)
      |> Repo.all()

    from(m in Model, where: m.spec_id == ^spec_id and m.id not in ^keep_ids) |> Repo.delete_all()
  end

  # GBM models (EXGBoost.Booster) have their own native binary format
  # (EXGBoost.dump_model/1, already a flat binary) - everything else (Scholar structs,
  # Axon.ModelState) goes through Nx.serialize/1, whose output is iodata (a list of
  # binaries, not always flat) and needs normalizing before it hits Ecto's :binary field.
  defp serialize_artifact(alg, model) when alg in ["gbm_classifier", "gbm_regressor"], do: EXGBoost.dump_model(model)
  defp serialize_artifact(_alg, model), do: IO.iodata_to_binary(Nx.serialize(model))

  defp mark_status(spec_id, status, error) do
    from(s in Spec, where: s.id == ^spec_id)
    |> Repo.update_all(set: [status: status, last_error: error, updated_at: System.system_time(:second)])

    :ok
  end

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: inspect(reason)

  defp next_version(spec_id) do
    case from(m in Model, where: m.spec_id == ^spec_id, select: max(m.version)) |> Repo.one() do
      nil -> 1
      max -> max + 1
    end
  end

  defp new_model_id, do: "insmodel_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

  defp models_for(spec_id) do
    from(m in Model, where: m.spec_id == ^spec_id, order_by: [desc: m.version])
    |> Repo.all()
    |> Enum.map(fn m ->
      %{
        "version" => m.version,
        "algorithm" => m.algorithm,
        "sample_count" => m.sample_count,
        "metric_name" => m.metric_name,
        "metric_value" => m.metric_value,
        "trained_at" => m.trained_at,
        # Only "kmeans" versions carry a non-empty "clusters" entry here (see
        # Trainer.fit_clustering/2) - the tool surface renders it when present.
        "clusters" => m.params["clusters"]
      }
    end)
  end

  ###
  ### validation
  ###

  defp validate(attrs) do
    []
    |> check_bool(present?(attrs["name"]), "a spec needs a non-empty \"name\"")
    |> check_bool(task_type(attrs) in @task_types, "task_type must be one of #{inspect(@task_types)}")
    |> validate_target(attrs)
    |> validate_time_column(attrs)
    |> check_bool(valid_feature_columns?(attrs), "feature_columns must be an array of identifiers")
    |> check_bool(valid_optional_integer?(attrs["retrain_interval_s"]), "retrain_interval_s must be an integer")
    |> check_bool(valid_optional_integer?(attrs["min_new_rows"]), "min_new_rows must be an integer")
    |> check_bool(valid_family?(attrs["family"]), "family must be one of #{inspect(@families)}, or omitted for automatic")
    |> validate_source(attrs["source"] || %{})
  end

  defp valid_family?(nil), do: true
  defp valid_family?(f), do: f in @families

  defp valid_optional_integer?(nil), do: true
  defp valid_optional_integer?(v), do: is_integer(v)

  # "clustering" has no target to predict - target_column stays nil. Every other task_type
  # needs one, "forecast" included (the value it predicts over time).
  defp validate_target(errors, %{"task_type" => "clustering"}), do: errors

  defp validate_target(errors, attrs) do
    check_bool(errors, present?(attrs["target_column"]) and identifier?(attrs["target_column"]), "target_column must be a valid identifier")
  end

  # Only "forecast" needs a time_column - it's nil for every other task_type.
  defp validate_time_column(errors, %{"task_type" => "forecast"} = attrs) do
    check_bool(errors, present?(attrs["time_column"]) and identifier?(attrs["time_column"]), "time_column must be a valid identifier")
  end

  defp validate_time_column(errors, _attrs), do: errors

  defp validate_source(errors, %{"kind" => "import"}), do: errors

  defp validate_source(errors, %{"kind" => "db", "connection" => connection, "table" => table})
       when is_binary(connection) and is_binary(table) do
    errors
    |> check_bool(identifier?(table), "table must be a valid identifier")
    |> check_bool(not is_nil(Config.db_connection(connection)), "no database connection named #{inspect(connection)}")
  end

  defp validate_source(errors, %{"kind" => "db"}), do: ["a \"db\" source needs \"connection\" and \"table\"" | errors]
  defp validate_source(errors, _source), do: ["\"source\".\"kind\" must be \"db\" or \"import\"" | errors]

  defp task_type(attrs), do: attrs["task_type"] || "classification"

  defp present?(v), do: is_binary(v) and v != ""
  defp identifier?(v), do: is_binary(v) and Regex.match?(@identifier, v)

  # "forecast" may have zero extra feature_columns (a pure time-based forecast, omitted or
  # explicitly []) - every other task_type needs at least one.
  defp valid_feature_columns?(attrs) do
    cols = attrs["feature_columns"] || []
    is_list(cols) and Enum.all?(cols, &identifier?/1) and (cols != [] or task_type(attrs) == "forecast")
  end

  defp check_bool(errors, true, _message), do: errors
  defp check_bool(errors, false, message), do: [message | errors]

  ###
  ### persistence helpers
  ###

  @spec_replace_on_conflict [
    :source_kind,
    :connection,
    :table,
    :target_column,
    :time_column,
    :feature_columns,
    :task_type,
    :family,
    :mode,
    :retrain_interval_s,
    :min_new_rows,
    :row_count_at_last_train,
    :status,
    :last_error,
    :updated_at
  ]

  defp save(agent_name, attrs) do
    existing = Repo.get_by(Spec, agent: agent_name, name: attrs["name"])
    source = attrs["source"] || %{}
    shape = spec_shape(attrs, source)
    reshaped? = reshaped?(existing, shape)
    row = build_row(agent_name, attrs, source, shape, existing, reshaped?)

    Repo.insert_all(Spec, [row], on_conflict: {:replace, @spec_replace_on_conflict}, conflict_target: [:agent, :name])
    get_spec(agent_name, attrs["name"])
  end

  # Forced to nil rather than trusting attrs directly: validate/1 only requires the right
  # column for the right task_type, it doesn't reject the WRONG one being present too - a
  # "clustering" spec saved with a stray target_column would otherwise make every
  # import_rows batch fail for demanding a column the spec doesn't actually use.
  defp spec_shape(attrs, source) do
    %{
      target_column: target_column_for(attrs),
      time_column: time_column_for(attrs),
      feature_columns: attrs["feature_columns"] || [],
      task_type: task_type(attrs),
      source_kind: source["kind"]
    }
  end

  defp reshaped?(nil, _shape), do: false

  # Any trained model was fit against the OLD target/features/task_type/source - if any of
  # those change, that model no longer means what its metadata claims (predict/3 would
  # otherwise keep answering silently from a stale, now-incompatible model). Reset back to
  # "pending" so the spec has to retrain under its new shape before predict serves it again.
  defp reshaped?(existing, shape) do
    existing.task_type != shape.task_type or existing.feature_columns != shape.feature_columns or
      existing.target_column != shape.target_column or existing.time_column != shape.time_column or
      existing.source_kind != shape.source_kind
  end

  defp build_row(agent_name, attrs, source, shape, existing, reshaped?) do
    %{
      agent: agent_name,
      name: attrs["name"],
      source_kind: shape.source_kind,
      connection: source["connection"],
      table: source["table"],
      target_column: shape.target_column,
      time_column: shape.time_column,
      feature_columns: shape.feature_columns,
      task_type: shape.task_type,
      family: family_for_attrs(attrs),
      mode: attrs["mode"] || "manual",
      retrain_interval_s: attrs["retrain_interval_s"],
      min_new_rows: attrs["min_new_rows"] || 50
    }
    |> Map.merge(existing_derived_fields(existing, reshaped?))
  end

  # The row_count_at_last_train/status/last_error fields tied to the old model's validity
  # never carry forward on a reshaped spec - see reshaped?/2's own note.
  defp existing_derived_fields(existing, reshaped?) do
    now = System.system_time(:second)

    %{
      id: (existing && existing.id) || new_spec_id(),
      row_count_at_last_train: carry_over(reshaped?, existing, :row_count_at_last_train, 0),
      status: carry_over(reshaped?, existing, :status, "pending"),
      last_error: if(reshaped?, do: nil, else: existing && existing.last_error),
      last_trained_at: existing && existing.last_trained_at,
      created_at: (existing && existing.created_at) || now,
      updated_at: now
    }
  end

  # A reshaped spec never carries a stale reading of a field tied to the old model's
  # validity (row_count_at_last_train, status) forward - see reshaped?/2's own note.
  defp carry_over(true, _existing, _field, reset_value), do: reset_value
  defp carry_over(false, existing, field, default), do: (existing && Map.fetch!(existing, field)) || default

  defp target_column_for(%{"task_type" => "clustering"}), do: nil
  defp target_column_for(attrs), do: attrs["target_column"]

  # "clustering" always uses k-means regardless of volume - an explicit family override
  # would be a silent no-op there, so it's dropped rather than persisted and ignored.
  defp family_for_attrs(%{"task_type" => "clustering"}), do: nil
  defp family_for_attrs(attrs), do: attrs["family"]

  defp time_column_for(%{"task_type" => "forecast"} = attrs), do: attrs["time_column"]
  defp time_column_for(_attrs), do: nil

  defp fetch_struct(agent_ref, name) do
    case canonical_agent(agent_ref) do
      nil -> nil
      agent -> Repo.get_by(Spec, agent: agent, name: name)
    end
  end

  defp canonical_agent(agent_ref) do
    case Config.get_agent(agent_ref) do
      nil -> nil
      agent -> agent.name
    end
  end

  defp new_spec_id, do: "insight_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

  defp to_map(%Spec{} = s) do
    %{
      "id" => s.id,
      "agent" => s.agent,
      "name" => s.name,
      "source_kind" => s.source_kind,
      "connection" => s.connection,
      "table" => s.table,
      "target_column" => s.target_column,
      "time_column" => s.time_column,
      "feature_columns" => s.feature_columns,
      "task_type" => s.task_type,
      "family" => s.family,
      "mode" => s.mode,
      "retrain_interval_s" => s.retrain_interval_s,
      "min_new_rows" => s.min_new_rows,
      "row_count_at_last_train" => s.row_count_at_last_train,
      "status" => s.status,
      "last_error" => s.last_error,
      "last_trained_at" => s.last_trained_at,
      "created_at" => s.created_at,
      "updated_at" => s.updated_at
    }
  end
end

defmodule Pepe.InsightTest do
  @moduledoc """
  `Pepe.Insight`'s durable-spec half (`define_spec/1`'s validation, upsert on
  `[agent, name]`) and the full `"import"` lifecycle end to end: import rows, train,
  predict, describe, delete. The `"db"`-sourced lifecycle needs a real Postgres and is
  exercised by manual verification instead.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Insight
  alias Pepe.Insight.Spec
  alias Pepe.Repo

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_insight_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.put_agent(%Agent{name: "clinic", system_prompt: "x", tools: []})
    :ok
  end

  defp import_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "agent" => "clinic",
        "name" => "risk",
        "target_column" => "deteriorating",
        "feature_columns" => ["age", "risk_score"],
        "source" => %{"kind" => "import"}
      },
      overrides
    )
  end

  defp rows(n) do
    for i <- 1..n do
      risk = if rem(i, 2) == 0, do: 1.0, else: 0.0
      %{"age" => 40 + i, "risk_score" => risk, "deteriorating" => if(risk > 0.5, do: "yes", else: "no")}
    end
  end

  describe "define_spec/1 - validation" do
    test "rejects an unknown agent" do
      assert {:error, {:invalid, [msg]}} = Insight.define_spec(%{"agent" => "ghost", "name" => "x"})
      assert msg =~ "unknown agent"
    end

    test "rejects a db source with no connection/table" do
      attrs = import_attrs(%{"source" => %{"kind" => "db"}})
      assert {:error, {:invalid, errors}} = Insight.define_spec(attrs)
      assert Enum.any?(errors, &(&1 =~ "connection"))
    end

    test "rejects a db source naming an unregistered connection" do
      attrs = import_attrs(%{"source" => %{"kind" => "db", "connection" => "nope", "table" => "events"}})
      assert {:error, {:invalid, errors}} = Insight.define_spec(attrs)
      assert Enum.any?(errors, &(&1 =~ "no database connection"))
    end

    test "rejects an empty feature_columns list" do
      assert {:error, {:invalid, errors}} = Insight.define_spec(import_attrs(%{"feature_columns" => []}))
      assert Enum.any?(errors, &(&1 =~ "feature_columns"))
    end

    test "rejects a bad task_type" do
      assert {:error, {:invalid, errors}} = Insight.define_spec(import_attrs(%{"task_type" => "astrology"}))
      assert Enum.any?(errors, &(&1 =~ "task_type"))
    end

    test "rejects a string retrain_interval_s instead of crashing on insert" do
      assert {:error, {:invalid, errors}} = Insight.define_spec(import_attrs(%{"retrain_interval_s" => "3600"}))
      assert Enum.any?(errors, &(&1 =~ "retrain_interval_s"))
    end

    test "rejects a string min_new_rows instead of crashing on insert" do
      assert {:error, {:invalid, errors}} = Insight.define_spec(import_attrs(%{"min_new_rows" => "50"}))
      assert Enum.any?(errors, &(&1 =~ "min_new_rows"))
    end

    test "a clustering spec ignores a stray target_column instead of persisting it" do
      attrs = %{
        "agent" => "clinic",
        "name" => "segments",
        "target_column" => "should_be_dropped",
        "feature_columns" => ["age"],
        "task_type" => "clustering",
        "source" => %{"kind" => "import"}
      }

      assert {:ok, spec} = Insight.define_spec(attrs)
      assert spec["target_column"] == nil
    end

    test "rejects an unknown family" do
      assert {:error, {:invalid, errors}} = Insight.define_spec(import_attrs(%{"family" => "quantum"}))
      assert Enum.any?(errors, &(&1 =~ "family"))
    end

    test "accepts a valid family override" do
      assert {:ok, spec} = Insight.define_spec(import_attrs(%{"family" => "gbm"}))
      assert spec["family"] == "gbm"
    end

    test "a clustering spec ignores a stray family instead of persisting it" do
      attrs = %{
        "agent" => "clinic",
        "name" => "segments",
        "feature_columns" => ["age"],
        "task_type" => "clustering",
        "family" => "neural",
        "source" => %{"kind" => "import"}
      }

      assert {:ok, spec} = Insight.define_spec(attrs)
      assert spec["family"] == nil
    end
  end

  describe "define_spec/1 - upsert" do
    test "defines then upserts on [agent, name], keeping the same id" do
      assert {:ok, spec} = Insight.define_spec(import_attrs())
      assert spec["source_kind"] == "import"
      assert spec["status"] == "pending"

      assert {:ok, spec2} = Insight.define_spec(import_attrs(%{"min_new_rows" => 5}))
      assert spec2["id"] == spec["id"]
      assert spec2["min_new_rows"] == 5
    end
  end

  describe "import_rows/4" do
    test "refuses on a \"db\" spec" do
      Config.put_db_connection("pg1", %{
        "engine" => "postgres",
        "host" => "h",
        "port" => 5432,
        "database" => "d",
        "user" => "u",
        "password" => "p"
      })

      attrs = import_attrs(%{"name" => "dbspec", "source" => %{"kind" => "db", "connection" => "pg1", "table" => "events"}})
      assert {:ok, _} = Insight.define_spec(attrs)

      assert {:error, msg} = Insight.import_rows("clinic", "dbspec", [%{"age" => 1, "risk_score" => 1.0, "deteriorating" => "yes"}])
      assert msg =~ "\"db\" spec"
    end

    test "returns :not_found for an unknown spec" do
      assert {:error, :not_found} = Insight.import_rows("clinic", "ghost", [%{}])
    end

    test "a full 5,000-row batch inserts without hitting SQLite's bind-parameter limit" do
      {:ok, _spec} = Insight.define_spec(import_attrs())
      assert {:ok, result} = Insight.import_rows("clinic", "risk", rows(5_000))
      assert result["inserted"] == 5_000
      assert result["total_examples"] == 5_000
    end
  end

  describe "full import -> train -> predict lifecycle" do
    setup do
      {:ok, _spec} = Insight.define_spec(import_attrs())
      :ok
    end

    test "predict refuses before anything has been trained" do
      assert {:error, msg} = Insight.predict("clinic", "risk", %{"age" => 50, "risk_score" => 1.0})
      assert msg =~ "train_now"
    end

    test "imports rows, trains, predicts, and updates spec/model bookkeeping" do
      assert {:ok, result} = Insight.import_rows("clinic", "risk", rows(30))
      assert result["inserted"] == 30
      assert result["total_examples"] == 30

      assert {:ok, trained} = Insight.train_now("clinic", "risk")
      assert trained["version"] == 1
      assert trained["metric_name"] == "accuracy"
      assert is_float(trained["metric_value"])

      assert {:ok, label} = Insight.predict("clinic", "risk", %{"age" => 50, "risk_score" => 1.0})
      assert label in ["yes", "no"]

      spec = Insight.get_spec("clinic", "risk")
      assert spec["status"] == "ready"
      assert spec["row_count_at_last_train"] == 30
      assert spec["last_error"] == nil

      described = Insight.describe("clinic", "risk")
      assert [%{"version" => 1, "algorithm" => "logistic_regression"}] = described["models"]

      # Retraining after more data bumps the version instead of replacing it.
      {:ok, _} = Insight.import_rows("clinic", "risk", rows(10))
      assert {:ok, %{"version" => 2}} = Insight.train_now("clinic", "risk")
    end

    test "redefining a trained spec with a different shape resets it, instead of predict quietly serving the old model" do
      {:ok, _} = Insight.import_rows("clinic", "risk", rows(30))
      {:ok, _} = Insight.train_now("clinic", "risk")
      assert Insight.get_spec("clinic", "risk")["status"] == "ready"

      assert {:ok, respec} = Insight.define_spec(import_attrs(%{"feature_columns" => ["age"]}))
      assert respec["status"] == "pending"
      assert respec["row_count_at_last_train"] == 0

      assert {:error, msg} = Insight.predict("clinic", "risk", %{"age" => 50})
      assert msg =~ "not ready"
      assert msg =~ "train_now"

      {:ok, _} = Insight.train_now("clinic", "risk")
      assert {:ok, _} = Insight.predict("clinic", "risk", %{"age" => 50})
    end

    test "picks the gradient-boosting tier once there's enough data (mid-size family threshold)" do
      {:ok, _} = Insight.import_rows("clinic", "risk", rows(2100))
      assert {:ok, trained} = Insight.train_now("clinic", "risk")
      assert trained["algorithm"] == "gbm_classifier"

      assert {:ok, label} = Insight.predict("clinic", "risk", %{"age" => 50, "risk_score" => 1.0})
      assert label in ["yes", "no"]
    end

    test "an explicit family override wins over the automatic, volume-based choice" do
      {:ok, _} = Insight.define_spec(import_attrs(%{"family" => "gbm"}))
      # Only 30 rows - well under the small-data threshold, which would otherwise pick
      # logistic_regression automatically. The explicit override must still win.
      {:ok, _} = Insight.import_rows("clinic", "risk", rows(30))

      assert {:ok, trained} = Insight.train_now("clinic", "risk")
      assert trained["algorithm"] == "gbm_classifier"
    end

    # Above @large_data_threshold - the one tier that has no test coverage without this,
    # since training it uncompiled would be unboundedly slow (the exact reason it now runs
    # JIT-compiled via EXLA - see Pepe.Insight.Neural). Bounded to a generous timeout rather
    # than asserting a specific duration: proving "finishes at all, reasonably fast" is the
    # point, not pinning an exact number sensitive to whatever machine runs the suite.
    @tag timeout: 120_000
    test "picks the large-data (neural) tier once there's enough data, and trains it in bounded time via EXLA" do
      Enum.each(1..11, fn _ -> {:ok, _} = Insight.import_rows("clinic", "risk", rows(4_600)) end)

      {micros, result} = :timer.tc(fn -> Insight.train_now("clinic", "risk") end)
      assert {:ok, trained} = result
      assert trained["algorithm"] == "neural_classifier"
      # Generous upper bound (EXLA's first JIT compilation in a test run is the slow part) -
      # this is a regression guard against "silently fell back to uncompiled and took
      # minutes", not a tight performance assertion.
      assert micros < 60_000_000

      assert {:ok, label} = Insight.predict("clinic", "risk", %{"age" => 50, "risk_score" => 1.0})
      assert label in ["yes", "no"]
    end

    test "a spec with too few rows fails training with a clear reason and status" do
      {:ok, _} = Insight.import_rows("clinic", "risk", rows(5))
      assert {:error, msg} = Insight.train_now("clinic", "risk")
      assert msg =~ "at least"

      spec = Insight.get_spec("clinic", "risk")
      assert spec["status"] == "failed"
      assert spec["last_error"] =~ "at least"
    end

    test "a few rows with a null feature value are dropped, not fatal to the whole fit" do
      clean = rows(40)
      # A stored example can carry an explicit nil for a column it has (unlike a batch
      # missing the column entirely, which import_rows itself already rejects) - a real
      # production table's occasional NULL looks exactly like this once fetched.
      nulled = for r <- rows(3), do: Map.put(r, "age", nil)

      {:ok, _} = Insight.import_rows("clinic", "risk", clean ++ nulled)
      assert {:ok, _trained} = Insight.train_now("clinic", "risk")
      assert Insight.get_spec("clinic", "risk")["status"] == "ready"
    end

    test "too many rows with a null feature value fails the fit with a clear reason" do
      clean = rows(10)
      nulled = for r <- rows(20), do: Map.put(r, "age", nil)

      {:ok, _} = Insight.import_rows("clinic", "risk", clean ++ nulled)
      assert {:error, msg} = Insight.train_now("clinic", "risk")
      assert msg =~ "missing value"
    end

    test "delete removes the spec, its models, and imported examples" do
      {:ok, _} = Insight.import_rows("clinic", "risk", rows(25))
      {:ok, _} = Insight.train_now("clinic", "risk")

      assert :ok = Insight.delete_spec("clinic", "risk")
      assert Insight.get_spec("clinic", "risk") == nil
      assert {:error, :not_found} = Insight.delete_spec("clinic", "risk")
    end

    test "train_now refuses to start while a run is already claimed, instead of racing it" do
      {:ok, _} = Insight.import_rows("clinic", "risk", rows(30))
      spec = Insight.get_spec("clinic", "risk")

      # Simulate a run already in flight (as the scheduler's own train_now call would leave
      # it) without going through train_now - proves the guard is a real DB-level claim, not
      # just "two sequential calls happen to serialize".
      from(s in Spec, where: s.id == ^spec["id"]) |> Repo.update_all(set: [status: "training"])

      assert Insight.train_now("clinic", "risk") == {:error, :already_training}
      assert Insight.describe("clinic", "risk")["models"] == []
    end

    test "reconcile_stuck_training fails a spec left \"training\" by an interrupted run" do
      {:ok, _} = Insight.import_rows("clinic", "risk", rows(30))
      spec = Insight.get_spec("clinic", "risk")
      from(s in Spec, where: s.id == ^spec["id"]) |> Repo.update_all(set: [status: "training"])

      assert :ok = Insight.reconcile_stuck_training()

      reconciled = Insight.get_spec("clinic", "risk")
      assert reconciled["status"] == "failed"
      assert reconciled["last_error"] =~ "interrupted"
    end
  end

  describe "categorical feature columns" do
    test "one-hot encodes a non-numeric feature column and persists its vocabulary" do
      attrs = %{
        "agent" => "clinic",
        "name" => "plan",
        "target_column" => "churned",
        "feature_columns" => ["tenure_months", "plan_tier"],
        "source" => %{"kind" => "import"}
      }

      {:ok, _} = Insight.define_spec(attrs)

      rows =
        for i <- 1..40 do
          tier = Enum.at(["free", "pro", "enterprise"], rem(i, 3))
          %{"tenure_months" => i, "plan_tier" => tier, "churned" => if(tier == "free", do: "yes", else: "no")}
        end

      {:ok, _} = Insight.import_rows("clinic", "plan", rows)
      assert {:ok, trained} = Insight.train_now("clinic", "plan")
      assert is_float(trained["metric_value"])

      spec = Insight.get_spec("clinic", "plan")
      model = Insight.latest_model(spec["id"])
      assert model.params["categories"]["plan_tier"] == ["enterprise", "free", "pro"]

      assert {:ok, label} = Insight.predict("clinic", "plan", %{"tenure_months" => 5, "plan_tier" => "free"})
      assert label in ["yes", "no"]
    end

    test "an unseen category at predict time falls back gracefully instead of crashing" do
      attrs = %{
        "agent" => "clinic",
        "name" => "plan",
        "target_column" => "churned",
        "feature_columns" => ["tenure_months", "plan_tier"],
        "source" => %{"kind" => "import"}
      }

      {:ok, _} = Insight.define_spec(attrs)

      rows =
        for i <- 1..40 do
          tier = Enum.at(["free", "pro"], rem(i, 2))
          %{"tenure_months" => i, "plan_tier" => tier, "churned" => if(tier == "free", do: "yes", else: "no")}
        end

      {:ok, _} = Insight.import_rows("clinic", "plan", rows)
      {:ok, _} = Insight.train_now("clinic", "plan")

      assert {:ok, label} = Insight.predict("clinic", "plan", %{"tenure_months" => 5, "plan_tier" => "never_seen_before"})
      assert label in ["yes", "no"]
    end

    test "a categorical column with too many distinct values fails training with a clear message" do
      attrs = %{
        "agent" => "clinic",
        "name" => "wide",
        "target_column" => "y",
        "feature_columns" => ["id_like"],
        "source" => %{"kind" => "import"}
      }

      {:ok, _} = Insight.define_spec(attrs)
      rows = for i <- 1..30, do: %{"id_like" => "user_#{i}", "y" => if(rem(i, 2) == 0, do: "a", else: "b")}
      {:ok, _} = Insight.import_rows("clinic", "wide", rows)

      assert {:error, msg} = Insight.train_now("clinic", "wide")
      assert msg =~ "too many"
    end

    test "regression also supports a categorical feature column" do
      attrs = %{
        "agent" => "clinic",
        "name" => "spend",
        "target_column" => "amount",
        "task_type" => "regression",
        "feature_columns" => ["region"],
        "source" => %{"kind" => "import"}
      }

      {:ok, _} = Insight.define_spec(attrs)

      rows =
        for i <- 1..40 do
          region = Enum.at(["north", "south"], rem(i, 2))
          amount = if region == "north", do: 100.0 + i, else: 10.0 + i
          %{"region" => region, "amount" => amount}
        end

      {:ok, _} = Insight.import_rows("clinic", "spend", rows)
      assert {:ok, trained} = Insight.train_now("clinic", "spend")
      assert trained["metric_name"] == "rmse"
    end
  end

  describe "cross-validation" do
    test "reports a cross-validated metric and refits the final model on every row, not just 80%" do
      attrs = %{
        "agent" => "clinic",
        "name" => "cv",
        "target_column" => "outcome",
        "feature_columns" => ["a"],
        "source" => %{"kind" => "import"}
      }

      {:ok, _} = Insight.define_spec(attrs)
      rows = for i <- 1..40, do: %{"a" => i, "outcome" => if(rem(i, 2) == 0, do: "yes", else: "no")}
      {:ok, _} = Insight.import_rows("clinic", "cv", rows)

      assert {:ok, trained} = Insight.train_now("clinic", "cv")
      assert is_float(trained["metric_value"])

      spec = Insight.get_spec("clinic", "cv")
      model = Insight.latest_model(spec["id"])
      assert model.params["cv_folds"] == 5
      assert is_float(model.params["metric_stddev"])
      assert model.sample_count == 40
    end
  end

  describe "feature standardization" do
    test "a class-separating small-scale feature isn't drowned out by a large-scale, uninformative one" do
      attrs = %{
        "agent" => "clinic",
        "name" => "scaled",
        "target_column" => "y",
        "feature_columns" => ["signal", "noise"],
        "source" => %{"kind" => "import"}
      }

      {:ok, _} = Insight.define_spec(attrs)

      # "signal" (0.0-1.0) alone determines the label; "noise" (millions) carries none of
      # it. Without per-feature standardization, gradient descent is dominated by noise's
      # raw scale and the model can't learn from signal at all.
      rows =
        for i <- 1..60 do
          signal = rem(i, 2) * 1.0
          %{"signal" => signal, "noise" => 1_000_000 + :rand.uniform(1000), "y" => if(signal > 0.5, do: "yes", else: "no")}
        end

      {:ok, _} = Insight.import_rows("clinic", "scaled", rows)
      assert {:ok, trained} = Insight.train_now("clinic", "scaled")
      assert trained["metric_value"] > 0.8
    end
  end

  describe "clustering lifecycle (no target_column)" do
    defp grouped_rows do
      group_a = for i <- 1..15, do: %{"age" => 20 + :rand.uniform(3), "spend" => 10 + :rand.uniform(3), "id" => i}
      group_b = for i <- 1..15, do: %{"age" => 60 + :rand.uniform(3), "spend" => 90 + :rand.uniform(3), "id" => i}
      group_a ++ group_b
    end

    test "defines without a target_column, trains, and describes cluster summaries" do
      attrs = %{
        "agent" => "clinic",
        "name" => "segments",
        "feature_columns" => ["age", "spend"],
        "task_type" => "clustering",
        "source" => %{"kind" => "import"}
      }

      assert {:ok, spec} = Insight.define_spec(attrs)
      assert spec["target_column"] == nil

      assert {:ok, _} = Insight.import_rows("clinic", "segments", grouped_rows())
      assert {:ok, trained} = Insight.train_now("clinic", "segments")
      assert trained["metric_name"] == "silhouette"

      described = Insight.describe("clinic", "segments")
      [model] = described["models"]
      assert model["algorithm"] == "kmeans"
      assert is_list(model["clusters"])
      assert match?([_, _ | _], model["clusters"])
      assert Enum.all?(model["clusters"], &(&1["size"] > 0))
    end

    # Scholar's silhouette scoring at the full @clustering_max_rows subsample cap is slow on
    # the plain Nx backend - EXLA is scoped to the neural tier only (see Pepe.Insight.Neural),
    # clustering never uses it - this test genuinely needs the extra time, not a sign of
    # something hanging.
    @tag timeout: 180_000
    test "row_count_at_last_train reflects the full population, not the clustering subsample cap" do
      attrs = %{
        "agent" => "clinic",
        "name" => "big_segments",
        "feature_columns" => ["age", "spend"],
        "task_type" => "clustering",
        "source" => %{"kind" => "import"}
      }

      {:ok, _} = Insight.define_spec(attrs)
      # Above @clustering_max_rows (1_500), so the fit itself subsamples - row_count_at_last_train
      # must still reflect every imported row, or the spec looks "no new rows" forever once its
      # example count first crosses the subsample cap.
      big_group = for i <- 1..900, do: %{"age" => 20 + rem(i, 3), "spend" => 10 + rem(i, 3)}
      {:ok, _} = Insight.import_rows("clinic", "big_segments", big_group ++ big_group)
      assert {:ok, _} = Insight.train_now("clinic", "big_segments")

      spec = Insight.get_spec("clinic", "big_segments")
      assert spec["row_count_at_last_train"] == 1_800
    end

    test "predict returns a cluster + anomaly verdict, not a bare value" do
      attrs = %{
        "agent" => "clinic",
        "name" => "segments",
        "feature_columns" => ["age", "spend"],
        "task_type" => "clustering",
        "source" => %{"kind" => "import"}
      }

      {:ok, _} = Insight.define_spec(attrs)
      {:ok, _} = Insight.import_rows("clinic", "segments", grouped_rows())
      {:ok, _} = Insight.train_now("clinic", "segments")

      assert {:ok, near} = Insight.predict("clinic", "segments", %{"age" => 21, "spend" => 11})
      assert is_integer(near["cluster"])
      assert near["anomalous"] == false

      assert {:ok, far} = Insight.predict("clinic", "segments", %{"age" => 5000, "spend" => 5000})
      assert far["anomalous"] == true
    end

    test "degenerate low-cardinality data fails cleanly instead of crashing and leaving the spec stuck" do
      attrs = %{
        "agent" => "clinic",
        "name" => "degenerate",
        "feature_columns" => ["a", "b"],
        "task_type" => "clustering",
        "source" => %{"kind" => "import"}
      }

      {:ok, _} = Insight.define_spec(attrs)
      # Every row is the exact same point - there is only one distinct value to cluster,
      # so every candidate k from 2 up forces an empty cluster and a NaN silhouette score.
      rows = for _i <- 1..24, do: %{"a" => 5, "b" => 5}
      {:ok, _} = Insight.import_rows("clinic", "degenerate", rows)

      assert {:error, _reason} = Insight.train_now("clinic", "degenerate")

      spec = Insight.get_spec("clinic", "degenerate")
      assert spec["status"] == "failed"
      refute spec["status"] == "training"
    end
  end

  describe "forecast lifecycle (time_column, no feature_columns)" do
    defp daily_rows(n) do
      start = ~D[2026-01-01]

      for i <- 0..(n - 1) do
        %{"day" => Date.add(start, i) |> Date.to_iso8601(), "sales" => 100 + i * 2}
      end
    end

    test "defines with a time_column, trains, and predicts a future date" do
      attrs = %{
        "agent" => "clinic",
        "name" => "sales_forecast",
        "target_column" => "sales",
        "time_column" => "day",
        "task_type" => "forecast",
        "source" => %{"kind" => "import"}
      }

      assert {:ok, spec} = Insight.define_spec(attrs)
      assert spec["feature_columns"] == []
      assert spec["time_column"] == "day"

      assert {:ok, _} = Insight.import_rows("clinic", "sales_forecast", daily_rows(30))
      assert {:ok, trained} = Insight.train_now("clinic", "sales_forecast")
      assert trained["metric_name"] == "rmse"
      assert trained["algorithm"] in ["linear_regression", "gbm_regressor", "neural_regressor"]

      # Day 40 continues the trend (100 + 40*2 = 180) - predicting a date past the training
      # window is the whole point of a forecast.
      assert {:ok, value} = Insight.predict("clinic", "sales_forecast", %{"day" => "2026-02-10"})
      assert is_number(value)
      assert_in_delta value, 180, 40
    end

    test "rejects a forecast spec with no time_column" do
      attrs = %{
        "agent" => "clinic",
        "name" => "bad_forecast",
        "target_column" => "sales",
        "task_type" => "forecast",
        "source" => %{"kind" => "import"}
      }

      assert {:error, {:invalid, errors}} = Insight.define_spec(attrs)
      assert Enum.any?(errors, &(&1 =~ "time_column"))
    end
  end
end

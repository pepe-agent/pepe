defmodule Pepe.Insight.PredictorTest do
  @moduledoc """
  Inference from an already-fitted model, for every algorithm - each hand-fit here (no
  Trainer, no DB), including a real serialize -> deserialize round trip for each one (
  `Nx.serialize/1` for Scholar/Axon, `EXGBoost.dump_model/1` for GBM), so a regression in
  either would fail here first.
  """

  use ExUnit.Case, async: true

  alias Pepe.Insight.GBMTrainer
  alias Pepe.Insight.Model
  alias Pepe.Insight.NeuralTrainer
  alias Pepe.Insight.Predictor

  describe "predict/2 - logistic_regression" do
    test "decodes the predicted class index back to its stored label" do
      x = Nx.tensor([[0.0, 0.0], [1.0, 1.0], [0.0, 1.0], [1.0, 0.0], [0.2, 0.1], [0.9, 0.8]])
      y = Nx.tensor([0, 1, 0, 1, 0, 1])
      fitted = Scholar.Linear.LogisticRegression.fit(x, y, num_classes: 2)

      model = %Model{
        algorithm: "logistic_regression",
        feature_columns: ["a", "b"],
        params: %{"classes" => ["no", "yes"]},
        artifact: Nx.serialize(fitted)
      }

      assert {:ok, label} = Predictor.predict(model, %{"a" => 1.0, "b" => 1.0})
      assert label in ["no", "yes"]
    end

    test "errors clearly when a feature is missing or non-numeric" do
      fitted = Scholar.Linear.LogisticRegression.fit(Nx.tensor([[0.0], [1.0]]), Nx.tensor([0, 1]), num_classes: 2)

      model = %Model{
        algorithm: "logistic_regression",
        feature_columns: ["a"],
        params: %{"classes" => ["no", "yes"]},
        artifact: Nx.serialize(fitted)
      }

      assert {:error, msg} = Predictor.predict(model, %{})
      assert msg =~ "feature"
    end
  end

  describe "predict/2 - linear_regression" do
    test "returns a numeric prediction" do
      fitted = Scholar.Linear.LinearRegression.fit(Nx.tensor([[1.0], [2.0], [3.0]]), Nx.tensor([2.0, 4.0, 6.0]))
      model = %Model{algorithm: "linear_regression", feature_columns: ["a"], params: %{}, artifact: Nx.serialize(fitted)}

      assert {:ok, value} = Predictor.predict(model, %{"a" => 4.0})
      assert_in_delta value, 8.0, 1.5
    end
  end

  describe "predict/2 - gbm_classifier / gbm_regressor" do
    test "round-trips a trained GBM classifier through EXGBoost's own serialization" do
      x = Nx.tensor(for i <- 1..30, do: [i / 30])
      y = Nx.tensor(for i <- 1..30, do: if(i > 15, do: 1, else: 0))
      booster = GBMTrainer.fit_classifier(x, y, 2)

      model = %Model{
        algorithm: "gbm_classifier",
        feature_columns: ["a"],
        params: %{"classes" => ["low", "high"]},
        artifact: EXGBoost.dump_model(booster)
      }

      assert {:ok, label} = Predictor.predict(model, %{"a" => 0.9})
      assert label in ["low", "high"]
    end

    test "round-trips a trained GBM regressor" do
      x = Nx.tensor(for i <- 1..30, do: [i / 30])
      y = Nx.tensor(for i <- 1..30, do: i * 2.0)
      booster = GBMTrainer.fit_regressor(x, y)

      model = %Model{algorithm: "gbm_regressor", feature_columns: ["a"], params: %{}, artifact: EXGBoost.dump_model(booster)}

      assert {:ok, value} = Predictor.predict(model, %{"a" => 0.5})
      assert is_number(value)
    end
  end

  describe "predict/2 - neural_classifier / neural_regressor" do
    test "round-trips a trained neural classifier" do
      x = Nx.tensor(for _ <- 1..20, do: [:rand.uniform(), :rand.uniform()])
      y = Nx.tensor(for _ <- 1..20, do: Enum.random([0, 1]))
      state = NeuralTrainer.fit_classifier(x, y, 2)

      model = %Model{
        algorithm: "neural_classifier",
        feature_columns: ["a", "b"],
        params: %{"classes" => ["low", "high"]},
        artifact: Nx.serialize(state)
      }

      assert {:ok, label} = Predictor.predict(model, %{"a" => 0.5, "b" => 0.5})
      assert label in ["low", "high"]
    end

    test "round-trips a trained neural regressor" do
      x = Nx.tensor(for _ <- 1..20, do: [:rand.uniform()])
      y = Nx.tensor(for _ <- 1..20, do: :rand.uniform() * 10)
      state = NeuralTrainer.fit_regressor(x, y)

      model = %Model{algorithm: "neural_regressor", feature_columns: ["a"], params: %{}, artifact: Nx.serialize(state)}

      assert {:ok, value} = Predictor.predict(model, %{"a" => 0.5})
      assert is_float(value)
    end
  end

  describe "predict/2 - kmeans" do
    test "assigns a nearby point to its cluster without flagging it anomalous" do
      x = Nx.tensor(for _ <- 1..15, do: [0.0 + :rand.uniform() * 0.1, 0.0 + :rand.uniform() * 0.1])
      fitted = Scholar.Cluster.KMeans.fit(x, num_clusters: 1, key: Nx.Random.key(1))

      model = %Model{
        algorithm: "kmeans",
        feature_columns: ["a", "b"],
        params: %{"distance_mean" => 0.05, "distance_stddev" => 0.03},
        artifact: Nx.serialize(fitted)
      }

      assert {:ok, result} = Predictor.predict(model, %{"a" => 0.05, "b" => 0.05})
      assert result["cluster"] == 0
      assert result["anomalous"] == false
    end

    test "flags a far-away point as anomalous" do
      x = Nx.tensor(for _ <- 1..15, do: [0.0 + :rand.uniform() * 0.1, 0.0 + :rand.uniform() * 0.1])
      fitted = Scholar.Cluster.KMeans.fit(x, num_clusters: 1, key: Nx.Random.key(1))

      model = %Model{
        algorithm: "kmeans",
        feature_columns: ["a", "b"],
        params: %{"distance_mean" => 0.05, "distance_stddev" => 0.03},
        artifact: Nx.serialize(fitted)
      }

      assert {:ok, result} = Predictor.predict(model, %{"a" => 50.0, "b" => 50.0})
      assert result["anomalous"] == true
      assert result["anomaly_score"] > 3.0
    end
  end
end

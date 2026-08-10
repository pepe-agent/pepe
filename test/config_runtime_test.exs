defmodule ConfigRuntimeTest do
  @moduledoc """
  `config/runtime.exs` decides the HTTP bind address: loopback by default (a bare
  `mix pepe serve`/installed binary has no reverse proxy in front, so a wider bind
  would expose the unauthenticated `/v1` API - see PepeWeb.Router's `:v1_api`
  pipeline comment, "open when no tokens exist"), `0.0.0.0` only when `PEPE_SERVE`
  is set (the official Docker image's boot path, where the container boundary is
  the real perimeter and a sibling reverse-proxy container needs to reach it).
  """
  # async: false - System.put_env/2 is process-wide, not per-BEAM-process, so this
  # can't safely run alongside another test reading PEPE_SERVE/PORT.
  use ExUnit.Case, async: false

  defp http_config(env_overrides) do
    env_overrides = Enum.map(env_overrides, fn {k, v} -> {to_string(k), v} end)
    prev = Enum.map(env_overrides, fn {k, _} -> {k, System.get_env(k)} end)

    Enum.each(env_overrides, fn
      {k, nil} -> System.delete_env(k)
      {k, v} -> System.put_env(k, v)
    end)

    result =
      "config/runtime.exs"
      |> Config.Reader.read!(env: :prod, target: :host)
      |> get_in([:pepe, PepeWeb.Endpoint, :http])

    Enum.each(prev, fn
      {k, nil} -> System.delete_env(k)
      {k, v} -> System.put_env(k, v)
    end)

    result
  end

  test "binds to loopback by default (PEPE_SERVE unset)" do
    assert http_config(PEPE_SERVE: nil, PORT: nil)[:ip] == {127, 0, 0, 1}
  end

  test "binds to every interface under PEPE_SERVE (the Docker boot path)" do
    assert http_config(PEPE_SERVE: "1", PORT: nil)[:ip] == {0, 0, 0, 0}
  end

  test "PORT still applies under either bind" do
    assert http_config(PEPE_SERVE: nil, PORT: "5050")[:port] == 5050
    assert http_config(PEPE_SERVE: "1", PORT: "5051")[:port] == 5051
  end
end

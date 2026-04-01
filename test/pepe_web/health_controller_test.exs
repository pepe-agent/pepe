defmodule PepeWeb.HealthControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_health_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  defp write_config(home, config), do: File.write!(Path.join(home, "config.json"), Jason.encode!(config))

  test "is a minimal probe that never leaks agent or model names", %{home: home} do
    write_config(home, %{
      "models" => %{"secret-model" => %{"base_url" => "x", "api_key" => "y", "model" => "z"}},
      "agents" => %{"secret-agent" => %{"model" => "secret-model", "system_prompt" => "x", "tools" => []}}
    })

    body = build_conn() |> get("/health") |> json_response(200)

    assert body["status"] == "ok"
    assert body["service"] == "pepe"
    assert body["ready"] == true
    refute Map.has_key?(body, "agents")
    refute Map.has_key?(body, "models")
    refute body |> Jason.encode!() |> String.contains?("secret")
  end

  test "reports not-ready when no model or agent is configured", %{home: home} do
    write_config(home, %{})
    body = build_conn() |> get("/health") |> json_response(200)
    assert body["ready"] == false
  end
end

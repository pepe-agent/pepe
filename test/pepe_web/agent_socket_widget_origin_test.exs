defmodule PepeWeb.AgentSocketWidgetOriginTest do
  @moduledoc """
  `check_origin?/1` only confirms the connecting browser matches SOME registered
  widget origin (necessarily coarse, since the token isn't known yet at that point -
  see its doc). `connect/3` is what enforces the precise, per-token match once the
  token (and so its own `allowed_origin`) is resolved, using the real Origin header
  `PepeWeb.Endpoint.call/2` stashes via the process dictionary.
  """
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_widget_origin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.put_agent(%Pepe.Config.Agent{name: "assistant", system_prompt: "x", tools: []})
    Config.put_agent(%Pepe.Config.Agent{name: "other", system_prompt: "x", tools: []})

    {:ok, raw_a, _id} =
      Config.add_api_token(agent: "assistant", widget: true, allowed_origin: "https://a.example.com")

    # A second registered widget origin, so check_origin?/1's coarse gate would let
    # a connection from here through even though it isn't token_a's own origin -
    # this is exactly the scenario the per-token check must close.
    {:ok, _raw_b, _id} = Config.add_api_token(agent: "other", widget: true, allowed_origin: "https://b.example.com")

    %{token_a: raw_a}
  end

  defp conn_from(token, origin) do
    if origin, do: Process.put(:pepe_ws_request_origin, origin), else: Process.delete(:pepe_ws_request_origin)
    connect(PepeWeb.AgentSocket, %{"token" => token})
  end

  test "a widget token connects when the real Origin matches its own allowed_origin", %{token_a: token_a} do
    assert {:ok, _socket} = conn_from(token_a, "https://a.example.com")
  end

  test "a widget token is refused from a DIFFERENT registered widget's origin", %{token_a: token_a} do
    assert :error = conn_from(token_a, "https://b.example.com")
  end

  test "a widget token is refused from a totally unregistered origin", %{token_a: token_a} do
    assert :error = conn_from(token_a, "https://evil.example.com")
  end

  test "a widget token connects when no Origin header was captured (non-browser client, unchanged behavior)", %{
    token_a: token_a
  } do
    assert {:ok, _socket} = conn_from(token_a, nil)
  end

  test "a non-widget token is unaffected by any Origin mismatch" do
    {:ok, raw, _id} = Config.add_api_token(agent: "assistant")
    assert {:ok, _socket} = conn_from(raw, "https://totally-unrelated.example.com")
  end
end

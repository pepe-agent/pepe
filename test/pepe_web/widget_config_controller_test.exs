defmodule PepeWeb.WidgetConfigControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_wcc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Config.Agent{name: "assistant", system_prompt: "hi", tools: []})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "returns the appearance fields that were set, omitting the unset ones" do
    {:ok, raw, _id} =
      Config.add_api_token(
        agent: "assistant",
        widget: true,
        allowed_origin: "https://example.com",
        title: "Support",
        color: "#123456"
      )

    conn = get(build_conn(), "/plugin-assets/pepe-widget/config?token=#{URI.encode_www_form(raw)}")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["title"] == "Support"
    assert body["color"] == "#123456"
    refute Map.has_key?(body, "logo")
    refute Map.has_key?(body, "allowed_origin")
  end

  test "sets access-control-allow-origin to the token's allowed_origin" do
    {:ok, raw, _id} = Config.add_api_token(agent: "assistant", widget: true, allowed_origin: "https://example.com")

    conn = get(build_conn(), "/plugin-assets/pepe-widget/config?token=#{URI.encode_www_form(raw)}")

    assert get_resp_header(conn, "access-control-allow-origin") == ["https://example.com"]
  end

  test "404s an unknown or invalid token" do
    conn = get(build_conn(), "/plugin-assets/pepe-widget/config?token=pepe_nope")
    assert conn.status == 404
  end

  test "404s a valid but non-widget token" do
    {:ok, raw, _id} = Config.add_api_token(agent: "assistant")
    conn = get(build_conn(), "/plugin-assets/pepe-widget/config?token=#{URI.encode_www_form(raw)}")
    assert conn.status == 404
  end

  test "400s a missing token param" do
    conn = get(build_conn(), "/plugin-assets/pepe-widget/config")
    assert conn.status == 400
  end
end

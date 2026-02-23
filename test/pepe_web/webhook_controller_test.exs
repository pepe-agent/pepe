defmodule PepeWeb.WebhookControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_whctrl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_webhook("support", %{
      "provider" => "whatsapp",
      "company" => "acme",
      "agent" => "acme/support",
      "config" => %{"verify_token" => "vt", "app_secret" => "s3cr3t"}
    })

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "GET echoes the challenge when the verify token matches" do
    conn =
      get(build_conn(), "/webhooks/acme/whatsapp/support", %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => "vt",
        "hub.challenge" => "echo-me"
      })

    assert response(conn, 200) == "echo-me"
  end

  test "GET is forbidden when the verify token is wrong" do
    conn =
      get(build_conn(), "/webhooks/acme/whatsapp/support", %{
        "hub.verify_token" => "nope",
        "hub.challenge" => "x"
      })

    assert response(conn, 403)
  end

  test "GET on an unknown slug is forbidden" do
    conn = get(build_conn(), "/webhooks/acme/whatsapp/ghost", %{"hub.verify_token" => "vt"})
    assert response(conn, 403)
  end

  test "POST with an invalid signature is rejected (401)" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", "sha256=deadbeef")
      |> post("/webhooks/acme/whatsapp/support", ~s({"object":"whatsapp","entry":[]}))

    assert response(conn, 401)
  end
end

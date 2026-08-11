defmodule PepeWeb.BalanceWebhookControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Pepe.Config
  alias Pepe.Usage.Prepaid

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_balwh_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.add_project("acme")
    :ok
  end

  defp post_credit(project, body, headers \\ []) do
    conn = build_conn()
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    post(conn, "/webhooks/balance/#{project}", body)
  end

  test "404s (endpoint effectively off) when no secret is configured" do
    conn = post_credit("acme", %{"amount" => 10}, [{"authorization", "Bearer whatever"}])
    assert conn.status == 404
  end

  describe "with a secret configured" do
    setup do
      Config.save(Map.put(Config.load(), "balance_webhook_secret", "topsecret"))
      :ok
    end

    test "credits the balance with a valid bearer token and a positive amount" do
      conn = post_credit("acme", %{"amount" => 12.5}, [{"authorization", "Bearer topsecret"}])

      assert conn.status == 200
      assert %{"ok" => true, "balance" => 12.5} = Jason.decode!(conn.resp_body)
      assert_in_delta Prepaid.balance("acme"), 12.5, 0.0001
    end

    test "accepts the amount as a numeric string too" do
      conn = post_credit("acme", %{"amount" => "7.25"}, [{"authorization", "Bearer topsecret"}])

      assert conn.status == 200
      assert_in_delta Prepaid.balance("acme"), 7.25, 0.0001
    end

    test "401s with no Authorization header at all" do
      conn = post_credit("acme", %{"amount" => 10})
      assert conn.status == 401
      assert Prepaid.balance("acme") == nil
    end

    test "401s with the wrong token" do
      conn = post_credit("acme", %{"amount" => 10}, [{"authorization", "Bearer nope"}])
      assert conn.status == 401
      assert Prepaid.balance("acme") == nil
    end

    test "400s on a missing, zero, negative or non-numeric amount" do
      for body <- [%{}, %{"amount" => 0}, %{"amount" => -5}, %{"amount" => "not-a-number"}] do
        conn = post_credit("acme", body, [{"authorization", "Bearer topsecret"}])
        assert conn.status == 400, "expected 400 for #{inspect(body)}, got #{conn.status}"
      end

      assert Prepaid.balance("acme") == nil
    end

    test "\"root\" credits the default project scope, same as the CLI's scope_arg" do
      conn = post_credit("root", %{"amount" => 3}, [{"authorization", "Bearer topsecret"}])

      assert conn.status == 200
      assert_in_delta Prepaid.balance(nil), 3.0, 0.0001
    end
  end
end

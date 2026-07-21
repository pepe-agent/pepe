defmodule PepeWeb.WebhookRoundtripTest do
  @moduledoc """
  End-to-end: a signed WhatsApp webhook `POST` -> signature verified -> parsed -> the
  bound agent runs (against the local mock model) -> its reply is delivered. The
  Graph API call is stubbed with Mimic so nothing leaves the test.
  """
  use ExUnit.Case, async: false
  use Mimic

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint PepeWeb.Endpoint

  setup :set_mimic_global

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    home = Path.join(System.tmp_dir!(), "pepe_wh_rt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    config = %{
      "default_agent" => "acme/support",
      "models" => %{
        "mock" => %{
          "base_url" => "http://localhost:#{port}",
          "api_key" => "x",
          "model" => "mock-model"
        }
      },
      "companies" => %{"acme" => %{}},
      "agents" => %{
        "acme/support" => %{"model" => "mock", "system_prompt" => "You help.", "tools" => []}
      },
      "webhooks" => %{
        "support" => %{
          "provider" => "whatsapp",
          "project" => "acme",
          "agent" => "acme/support",
          "mode" => "support",
          "config" => %{"verify_token" => "vt", "app_secret" => "s3cr3t"}
        }
      }
    }

    File.write!(Path.join(home, "config.json"), Jason.encode!(config))

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "a signed inbound message runs the agent and delivers its reply" do
    test = self()

    stub(Pepe.Webhooks.WhatsApp, :deliver, fn _cfg, to, text ->
      send(test, {:delivered, to, text})
      :ok
    end)

    body =
      Jason.encode!(%{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "messages" => [
                    %{
                      "from" => "5511987654321",
                      "type" => "text",
                      "text" => %{"body" => "oi"},
                      "id" => "wamid.1"
                    }
                  ]
                }
              }
            ]
          }
        ]
      })

    sig =
      "sha256=" <> (:crypto.mac(:hmac, :sha256, "s3cr3t", body) |> Base.encode16(case: :lower))

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", sig)
      |> post("/webhooks/acme/whatsapp/support", body)

    # The webhook returns immediately...
    assert response(conn, 200) == "ok"
    # ...and the agent's reply is delivered back to the sender, off-process.
    assert_receive {:delivered, "5511987654321", "Hello from the mock!"}, 5_000
  end
end

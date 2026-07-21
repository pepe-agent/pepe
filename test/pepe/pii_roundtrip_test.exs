defmodule Pepe.PiiRoundtripTest do
  @moduledoc """
  End-to-end proof of the PII pipeline through a real session: the model must never see
  the raw PII (it is masked to a token on the way in), and the reply must come back with
  the real values restored (the reversible map on the way out).
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # A valid CPF (checksum passes) and an email, both structured PII the regex hook catches.
  @cpf "529.982.247-25"
  @email "john@acme.com"

  # A mock model that reports exactly what it received to the test, then echoes it back so
  # the outbound restore has something with the tokens in it to put real values into.
  defmodule EchoLLM do
    import Plug.Conn

    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, body, conn} = read_body(conn)
      messages = Jason.decode!(body)["messages"]
      seen = messages |> Enum.filter(&(&1["role"] == "user")) |> List.last() |> Map.get("content", "")
      send(pid, {:model_saw, seen})

      payload = %{
        "id" => "cmpl-1",
        "object" => "chat.completion",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "Confirmed: #{seen}"},
            "finish_reason" => "stop"
          }
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    {:ok, server} = Bandit.start_link(plug: {EchoLLM, self()}, scheme: :http, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    home = Path.join(System.tmp_dir!(), "pepe_pii_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    Config.put_hook_settings("pii_redact", %{"packs" => ["br", "intl"]})
    Config.put_model(%Model{name: "mock", base_url: "http://127.0.0.1:#{port}", api_key: "x", model: "m"})
    Config.put_agent(%Agent{name: "support", hooks: ["pii_redact"], model: "mock", tools: []})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "the model never sees raw PII and the reply comes back restored" do
    prompt = "My CPF is #{@cpf} and my email is #{@email}, please confirm."
    {:ok, reply} = Pepe.Agent.chat("pii:1", "support", prompt)

    # what the model actually received: tokens, never the raw values
    assert_received {:model_saw, saw}
    refute saw =~ @cpf
    refute saw =~ @email
    assert saw =~ "[CPF_1]"
    assert saw =~ "[EMAIL_1]"

    # what the user gets back: the real values, restored from the reversible map
    assert reply =~ @cpf
    assert reply =~ @email
    refute reply =~ "[CPF_1]"
    refute reply =~ "[EMAIL_1]"
  end

  test "an aside (/btw) redacts PII in and restores it out, the same as a normal turn" do
    # The side-question path must not be the one that skips redaction: an aside sends the same
    # kind of user text to the provider, so the model must see tokens and the reply come back
    # restored, exactly as the main chat does above.
    prompt = "Side question: is #{@cpf} / #{@email} on file?"
    {:ok, reply} = Pepe.Agent.aside("pii:aside", "support", prompt)

    assert_received {:model_saw, saw}
    refute saw =~ @cpf
    refute saw =~ @email
    assert saw =~ "[CPF_1]"
    assert saw =~ "[EMAIL_1]"

    assert reply =~ @cpf
    assert reply =~ @email
    refute reply =~ "[CPF_1]"
  end

  test "with reversible off, the model still never sees raw PII and nothing is restored" do
    Config.put_hook_settings("pii_redact", %{"packs" => ["br", "intl"], "reversible" => false})

    {:ok, reply} = Pepe.Agent.chat("pii:2", "support", "My CPF is #{@cpf}.")

    assert_received {:model_saw, saw}
    refute saw =~ @cpf
    assert saw =~ "[CPF_1]"

    # one-way: the token is what remains in the reply (no map to restore from)
    refute reply =~ @cpf
    assert reply =~ "[CPF_1]"
  end
end

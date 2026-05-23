defmodule PepeWeb.AgentSocketTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias Pepe.ApiToken

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    config = %{
      "default_agent" => "assistant",
      "companies" => %{"acme" => %{}, "globex" => %{}},
      "agents" => %{
        "assistant" => %{"system_prompt" => "root"},
        "acme/vendas" => %{"system_prompt" => "a"},
        "globex/vendas" => %{"system_prompt" => "g"}
      },
      "api_tokens" => %{
        "tacme" => %{"hash" => ApiToken.hash("ctx_acme"), "project" => "acme", "agent" => nil}
      }
    }

    File.write!(Path.join(home, "config.json"), Jason.encode!(config))

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn(params), do: connect(PepeWeb.AgentSocket, params)

  test "with tokens configured, connecting without a token is refused" do
    assert :error = conn(%{})
    assert :error = conn(%{"token" => "ctx_nope"})
  end

  test "a project token connects and can join its own agents (bare name qualifies)" do
    {:ok, socket} = conn(%{"token" => "ctx_acme"})
    assert {:ok, _reply, _s} = subscribe_and_join(socket, "agent:acme/vendas", %{})

    {:ok, socket} = conn(%{"token" => "ctx_acme"})
    assert {:ok, _reply, _s} = subscribe_and_join(socket, "agent:vendas", %{})
  end

  test "a project token cannot join another project's or a root agent" do
    {:ok, socket} = conn(%{"token" => "ctx_acme"})
    assert {:error, %{reason: _}} = subscribe_and_join(socket, "agent:globex/vendas", %{})

    {:ok, socket} = conn(%{"token" => "ctx_acme"})
    assert {:error, %{reason: _}} = subscribe_and_join(socket, "agent:assistant", %{})
  end
end

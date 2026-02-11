defmodule CortexWeb.AgentSocketTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias Cortex.ApiToken

  @endpoint CortexWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:cortex)

    home = Path.join(System.tmp_dir!(), "cortex_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)

    config = %{
      "default_agent" => "assistant",
      "companies" => %{"acme" => %{}, "globex" => %{}},
      "agents" => %{
        "assistant" => %{"system_prompt" => "root"},
        "acme/vendas" => %{"system_prompt" => "a"},
        "globex/vendas" => %{"system_prompt" => "g"}
      },
      "api_tokens" => %{
        "tacme" => %{"hash" => ApiToken.hash("ctx_acme"), "company" => "acme", "agent" => nil}
      }
    }

    File.write!(Path.join(home, "config.json"), Jason.encode!(config))

    on_exit(fn ->
      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn(params), do: connect(CortexWeb.AgentSocket, params)

  test "with tokens configured, connecting without a token is refused" do
    assert :error = conn(%{})
    assert :error = conn(%{"token" => "ctx_nope"})
  end

  test "a company token connects and can join its own agents (bare name qualifies)" do
    {:ok, socket} = conn(%{"token" => "ctx_acme"})
    assert {:ok, _reply, _s} = subscribe_and_join(socket, "agent:acme/vendas", %{})

    {:ok, socket} = conn(%{"token" => "ctx_acme"})
    assert {:ok, _reply, _s} = subscribe_and_join(socket, "agent:vendas", %{})
  end

  test "a company token cannot join another company's or a root agent" do
    {:ok, socket} = conn(%{"token" => "ctx_acme"})
    assert {:error, %{reason: _}} = subscribe_and_join(socket, "agent:globex/vendas", %{})

    {:ok, socket} = conn(%{"token" => "ctx_acme"})
    assert {:error, %{reason: _}} = subscribe_and_join(socket, "agent:assistant", %{})
  end
end

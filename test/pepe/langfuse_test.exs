defmodule Pepe.LangfuseTest do
  # async: false - System.put_env/2 (LANGFUSE_*) is process-wide, and the mock
  # server registers a fixed process name.
  use ExUnit.Case, async: false

  alias Pepe.Langfuse

  setup do
    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLangfuse, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    prev = for k <- ~w(LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY LANGFUSE_BASE_URL), do: {k, System.get_env(k)}

    on_exit(fn ->
      Process.exit(server, :normal)

      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    System.put_env("LANGFUSE_PUBLIC_KEY", "pk-lf-test")
    System.put_env("LANGFUSE_SECRET_KEY", "sk-lf-test")
    System.put_env("LANGFUSE_BASE_URL", "http://localhost:#{port}")
    Pepe.Test.MockLangfuse.listen()

    :ok
  end

  # A fresh name per test - Pepe.Store's cache is one shared table for the whole
  # suite, not reset between tests, so reusing a name would make a later test's
  # first fetch silently hit an earlier test's cache entry instead of the server.
  defp unique_name(prefix \\ "persona"), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "enabled?/0 is false unless both keys are set" do
    System.delete_env("LANGFUSE_PUBLIC_KEY")
    refute Langfuse.enabled?()

    System.put_env("LANGFUSE_PUBLIC_KEY", "pk-lf-test")
    System.delete_env("LANGFUSE_SECRET_KEY")
    refute Langfuse.enabled?()

    System.put_env("LANGFUSE_SECRET_KEY", "sk-lf-test")
    assert Langfuse.enabled?()
  end

  test "fetch/1 returns {:error, :not_configured} when disabled, with no HTTP call" do
    System.delete_env("LANGFUSE_PUBLIC_KEY")
    assert Langfuse.fetch(unique_name()) == {:error, :not_configured}
    refute_receive {:langfuse_request, _, _}, 200
  end

  test "fetch/1 returns a text-type prompt's template" do
    name = unique_name()
    assert {:ok, text} = Langfuse.fetch(name)
    assert text == "persona for " <> name
  end

  test "fetch/1 sends HTTP Basic auth with the public/secret key pair" do
    Langfuse.fetch(unique_name())
    assert_receive {:langfuse_request, _path, [auth_header]}, 2000
    assert auth_header == "Basic " <> Base.encode64("pk-lf-test:sk-lf-test")
  end

  test "fetch/1 extracts the system-role message from a chat-type prompt" do
    assert {:ok, "hi there"} = Langfuse.fetch("chat:user=nope|system=hi there")
  end

  test "fetch/1 falls back to the first message when a chat-type prompt has no system role" do
    assert {:ok, "first message wins"} = Langfuse.fetch("chat:user=first message wins")
  end

  test "fetch/1 returns {:error, {:not_found, _}} for an unknown prompt" do
    assert {:error, {:not_found, _}} = Langfuse.fetch("missing-#{System.unique_integer([:positive])}")
  end

  test "fetch/1 rejects a blank or non-string name without any HTTP call" do
    assert Langfuse.fetch("") == {:error, :no_prompt_name}
    assert Langfuse.fetch(nil) == {:error, :no_prompt_name}
    refute_receive {:langfuse_request, _, _}, 200
  end

  test "a second fetch/1 for the same name is served from cache, no second HTTP call" do
    name = unique_name()

    assert {:ok, text} = Langfuse.fetch(name)
    assert_receive {:langfuse_request, _, _}, 2000

    assert Langfuse.fetch(name) == {:ok, text}
    refute_receive {:langfuse_request, _, _}, 200
  end

  test "a folder-path prompt name (containing a slash) still reaches the server as one request" do
    Langfuse.fetch("team/" <> unique_name())
    assert_receive {:langfuse_request, _path_info, _}, 2000
  end
end

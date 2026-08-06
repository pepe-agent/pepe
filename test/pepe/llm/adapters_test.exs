defmodule Pepe.LLM.AdaptersTest do
  use ExUnit.Case, async: false

  alias Pepe.LLM.Adapters

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_llmadapters_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "the two builtins are always in the registry" do
    assert Adapters.get("openai-responses") == Pepe.LLM.Responses
    assert Adapters.get("anthropic-messages") == Pepe.LLM.Messages
  end

  test "an unknown api resolves to nil (the caller falls through to plain completions)" do
    assert Adapters.get("something-nobody-registered") == nil
    assert Adapters.get(nil) == nil
  end

  test "an installed plugin adapter is discovered by its api/0", %{home: home} do
    File.write!(Path.join([home, "plugins", "fake_adapter.exs"]), """
    defmodule PepeAdaptersTest.Fake do
      @behaviour Pepe.LLM.Adapter
      def api, do: "fake-protocol"
      def chat(_model, _messages, _opts), do: {:ok, %{content: "fake", tool_calls: [], finish_reason: "stop", usage: nil}}
      def stream_chat(_model, _messages, _on_delta, _opts), do: {:ok, %{content: "fake", tool_calls: [], finish_reason: "stop", usage: nil}}
    end
    """)

    assert Adapters.get("fake-protocol") == PepeAdaptersTest.Fake
  end

  test "a plugin cannot override a builtin api name", %{home: home} do
    File.write!(Path.join([home, "plugins", "impostor.exs"]), """
    defmodule PepeAdaptersTest.Impostor do
      @behaviour Pepe.LLM.Adapter
      def api, do: "openai-responses"
      def chat(_model, _messages, _opts), do: {:ok, %{content: "impostor", tool_calls: [], finish_reason: "stop", usage: nil}}
      def stream_chat(_model, _messages, _on_delta, _opts), do: {:ok, %{content: "impostor", tool_calls: [], finish_reason: "stop", usage: nil}}
    end
    """)

    assert Adapters.get("openai-responses") == Pepe.LLM.Responses
  end

  test "a plugin whose api/0 itself raises is skipped, not fatal to the registry", %{home: home} do
    File.write!(Path.join([home, "plugins", "broken_api.exs"]), """
    defmodule PepeAdaptersTest.BrokenApi do
      @behaviour Pepe.LLM.Adapter
      def api, do: raise("boom")
      def chat(_model, _messages, _opts), do: {:ok, %{content: "x", tool_calls: [], finish_reason: "stop", usage: nil}}
      def stream_chat(_model, _messages, _on_delta, _opts), do: {:ok, %{content: "x", tool_calls: [], finish_reason: "stop", usage: nil}}
    end
    """)

    # The registry as a whole still resolves - a broken plugin's api/0 must not take down
    # every model call in the installation, builtins included.
    assert Adapters.get("openai-responses") == Pepe.LLM.Responses
    assert Adapters.get("anthropic-messages") == Pepe.LLM.Messages
  end
end

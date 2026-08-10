defmodule Pepe.LLMAdapterDispatchTest do
  @moduledoc "`Pepe.LLM.chat/3`/`stream_chat/4` actually route through a plugin-registered `api`, and isolate a crash in one."
  use ExUnit.Case, async: false

  alias Pepe.Config.Model

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_llmdispatch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "chat/3 dispatches to a plugin adapter matching model.api", %{home: home} do
    suffix = System.unique_integer([:positive])
    api = "dispatch-ok-#{suffix}"
    mod = Module.concat(PepeLLMDispatchTest, :"Ok#{suffix}")

    File.write!(Path.join([home, "plugins", "dispatch_ok.exs"]), """
    defmodule #{inspect(mod)} do
      @behaviour Pepe.LLM.Adapter
      def api, do: #{inspect(api)}
      def chat(_model, _messages, _opts), do: {:ok, %{content: "from the plugin", tool_calls: [], finish_reason: "stop", usage: nil}}
      def stream_chat(_model, _messages, on_delta, _opts) do
        on_delta.("from the plugin")
        {:ok, %{content: "from the plugin", tool_calls: [], finish_reason: "stop", usage: nil}}
      end
    end
    """)

    model = %Model{name: "m", base_url: "https://unused", model: "x", api: api}
    assert {:ok, %{content: "from the plugin"}} = Pepe.LLM.chat(model, [%{"role" => "user", "content" => "hi"}])

    parent = self()
    on_delta = fn text -> send(parent, {:delta, text}) end
    assert {:ok, %{content: "from the plugin"}} = Pepe.LLM.stream_chat(model, [], on_delta)
    assert_received {:delta, "from the plugin"}
  end

  test "a crashing plugin adapter surfaces as {:error, _}, not a raised exception", %{home: home} do
    suffix = System.unique_integer([:positive])
    api = "dispatch-boom-#{suffix}"
    mod = Module.concat(PepeLLMDispatchTest, :"Boom#{suffix}")

    File.write!(Path.join([home, "plugins", "dispatch_boom.exs"]), """
    defmodule #{inspect(mod)} do
      @behaviour Pepe.LLM.Adapter
      def api, do: #{inspect(api)}
      def chat(_model, _messages, _opts), do: raise("adapter boom")
      def stream_chat(_model, _messages, _on_delta, _opts), do: raise("adapter boom")
    end
    """)

    model = %Model{name: "m", base_url: "https://unused", model: "x", api: api}
    assert {:error, {:adapter_crashed, ^mod, _}} = Pepe.LLM.chat(model, [])
  end

  test "an unregistered api falls through to plain openai-completions (an HTTP call, which fails here for lack of a real server)" do
    model = %Model{name: "m", base_url: "http://127.0.0.1:1", model: "x", api: "no-such-adapter"}
    assert {:error, _} = Pepe.LLM.chat(model, [])
  end
end

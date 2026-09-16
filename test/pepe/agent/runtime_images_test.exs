defmodule Pepe.Agent.RuntimeImagesTest do
  @moduledoc """
  `opts[:images]` (an inbound photo/screenshot, attached by Pepe.LLM.with_images/2 to the
  last user message at send time - see Pepe.LLM.VisionTest for that half) has to actually
  reach `Pepe.LLM.chat/stream_chat`'s own `opts`, not just `Runtime.run/3`'s. It didn't: the
  tool-loop's `chat_opts` was rebuilt from scratch on every iteration
  (`[temperature: agent.temperature]` / `[tools: specs, temperature: agent.temperature]`)
  and never carried `opts[:images]` forward, so an attached image was silently dropped
  before it ever reached the model - on every surface that sets `images:` (Telegram photos,
  the dashboard's own vision-capable upload path), not just a hypothetical.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Runtime
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.LLM.Message

  # Records every request body; a tool call on the first turn only, so a run with tools
  # granted still exercises the SECOND chat_opts build site (loop/7's tool-offering clause),
  # not just the first.
  defmodule ImagePlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      body = Jason.decode!(raw)
      send(Process.whereis(:runtime_images_test_pid), {:req, body})
      last = body["messages"] |> List.last()

      message =
        if last["role"] == "tool" do
          %{"role" => "assistant", "content" => "done"}
        else
          tool_call = %{"id" => "call_1", "type" => "function", "function" => %{"name" => "bash", "arguments" => "{}"}}
          %{"role" => "assistant", "content" => nil, "tool_calls" => [tool_call]}
        end

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => message, "finish_reason" => if(last["role"] == "tool", do: "stop", else: "tool_calls")}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_rimg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Process.register(self(), :runtime_images_test_pid)
    {:ok, server} = Bandit.start_link(plug: ImagePlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    model = %Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model", vision: true}

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, model: model}
  end

  defp image, do: %{media_type: "image/png", data: Base.encode64("bytes")}

  test "an attached image reaches the outgoing request on a plain (no-tools) turn", %{model: model} do
    agent = %Agent{name: "seer", model: "mock", tools: [], max_iterations: 5}
    messages = [Message.system("sys"), Message.user("what is this?")]

    {:ok, _final, _all} = Runtime.run(agent, messages, model: model, images: [image()])

    assert_receive {:req, body}, 2_000
    last_user = body["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last()
    assert Enum.any?(last_user["content"], &(&1["type"] == "image_url"))
  end

  test "an attached image still reaches the request when the turn goes through a tool call", %{model: model} do
    agent = %Agent{name: "seer", model: "mock", tools: ["bash"], max_iterations: 5}
    messages = [Message.system("sys"), Message.user("what is this? also check disk space")]

    {:ok, _final, _all} = Runtime.run(agent, messages, model: model, images: [image()])

    # Two requests: the tool-call-offering turn, then the follow-up after the tool result.
    assert_receive {:req, first_body}, 2_000
    first_user = first_body["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last()
    assert Enum.any?(first_user["content"], &(&1["type"] == "image_url")), "image missing on the first (tool-offering) call"

    assert_receive {:req, second_body}, 2_000
    second_user = second_body["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last()
    assert Enum.any?(second_user["content"], &(&1["type"] == "image_url")), "image missing on the follow-up call after the tool result"
  end

  test "no images: the outgoing request is unaffected (plain string content)", %{model: model} do
    agent = %Agent{name: "seer", model: "mock", tools: [], max_iterations: 5}
    messages = [Message.system("sys"), Message.user("hello")]

    {:ok, _final, _all} = Runtime.run(agent, messages, model: model)

    assert_receive {:req, body}, 2_000
    last_user = body["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last()
    assert last_user["content"] == "hello"
  end
end

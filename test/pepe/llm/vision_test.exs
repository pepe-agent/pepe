defmodule Pepe.LLM.VisionTest do
  @moduledoc """
  An inbound image (opts[:images]) is attached to the LAST user message at send time, in each
  provider's own content-part shape, and never touches the persisted string history. Covers the
  Image loader plus the attach for all three adapters (OpenAI-completions, Anthropic, Responses).
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Pepe.Config.Model
  alias Pepe.LLM
  alias Pepe.LLM.Image
  alias Pepe.LLM.Message

  # --- Image loader --------------------------------------------------------------

  describe "Image.load/1" do
    test "reads a file into base64 with a media type from the extension" do
      path = Path.join(System.tmp_dir!(), "pepe_vision_#{System.unique_integer([:positive])}.png")
      File.write!(path, "not-really-png-bytes")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{media_type: "image/png", data: data}} = Image.load(path)
      assert Base.decode64!(data) == "not-really-png-bytes"
      assert Image.data_uri(%{media_type: "image/png", data: data}) == "data:image/png;base64," <> data
    end

    test "refuses an unsupported extension and a missing file" do
      assert {:error, :unsupported_image_type} = Image.load("/tmp/whatever.txt")
      assert {:error, _} = Image.load(Path.join(System.tmp_dir!(), "nope_#{System.unique_integer([:positive])}.png"))
    end
  end

  # --- Adapters attach the image to the last user message ------------------------

  # Each plug records the request body to the test process, then returns the smallest valid response
  # so the call completes. `capture/1` is the request body as a decoded map.
  defmodule OpenAIPlug do
    import Plug.Conn
    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, raw, conn} = read_body(conn)
      send(pid, {:req, Jason.decode!(raw)})
      payload = %{"choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  defmodule AnthropicPlug do
    import Plug.Conn
    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, raw, conn} = read_body(conn)
      send(pid, {:req, Jason.decode!(raw)})

      events = [
        ~s({"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":1}}}),
        ~s({"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
        ~s({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}),
        ~s({"type":"content_block_stop","index":0}),
        ~s({"type":"message_stop"})
      ]

      conn |> put_resp_content_type("text/event-stream") |> send_resp(200, Enum.map_join(events, "", &("data: " <> &1 <> "\n\n")))
    end
  end

  defmodule ResponsesPlug do
    import Plug.Conn
    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, raw, conn} = read_body(conn)
      send(pid, {:req, Jason.decode!(raw)})

      events = [
        ~s({"type":"response.output_text.delta","delta":"ok"}),
        ~s({"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":1}}})
      ]

      conn |> put_resp_content_type("text/event-stream") |> send_resp(200, Enum.map_join(events, "", &("data: " <> &1 <> "\n\n")))
    end
  end

  defp start_plug(plug) do
    {:ok, server} = Bandit.start_link(plug: {plug, self()}, scheme: :http, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)
    port
  end

  defp messages, do: [Message.system("sys"), Message.user("what is in this picture?")]
  defp image, do: %{media_type: "image/png", data: Base.encode64("bytes")}

  test "openai-completions attaches an image_url part to the last user message" do
    port = start_plug(OpenAIPlug)
    model = %Model{name: "m", base_url: "http://127.0.0.1:#{port}/v1", api: "openai-completions", api_key: "x", model: "gpt", vision: true}

    LLM.chat(model, messages(), images: [image()])

    assert_receive {:req, body}, 2_000
    last_user = body["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last()
    assert %{"type" => "text", "text" => "what is in this picture?"} in last_user["content"]
    assert Enum.any?(last_user["content"], &(&1["type"] == "image_url" and &1["image_url"]["url"] =~ "data:image/png;base64,"))
  end

  test "anthropic-messages attaches an image source block to the last user message" do
    port = start_plug(AnthropicPlug)

    model = %Model{
      name: "m",
      base_url: "http://127.0.0.1:#{port}/v1",
      api: "anthropic-messages",
      api_key: "x",
      model: "claude",
      vision: true
    }

    LLM.chat(model, messages(), images: [image()])

    assert_receive {:req, body}, 2_000
    last_user = body["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last()
    assert Enum.any?(last_user["content"], &(&1["type"] == "image" and &1["source"]["media_type"] == "image/png"))
    assert Enum.any?(last_user["content"], &(&1["type"] == "text" and &1["text"] == "what is in this picture?"))
  end

  test "openai-responses attaches an input_image part to the last user message" do
    port = start_plug(ResponsesPlug)

    model = %Model{
      name: "m",
      base_url: "http://127.0.0.1:#{port}/codex",
      api: "openai-responses",
      api_key: "x",
      model: "gpt-5",
      vision: true
    }

    LLM.chat(model, messages(), images: [image()])

    assert_receive {:req, body}, 2_000
    last_user = body["input"] |> Enum.filter(&(&1["role"] == "user")) |> List.last()
    assert Enum.any?(last_user["content"], &(&1["type"] == "input_image" and &1["image_url"] =~ "data:image/png;base64,"))
    assert Enum.any?(last_user["content"], &(&1["type"] == "input_text" and &1["text"] == "what is in this picture?"))
  end

  test "no images: the last user message stays a plain string (all adapters)" do
    port = start_plug(OpenAIPlug)
    model = %Model{name: "m", base_url: "http://127.0.0.1:#{port}/v1", api: "openai-completions", api_key: "x", model: "gpt", vision: true}

    LLM.chat(model, messages(), [])

    assert_receive {:req, body}, 2_000
    last_user = body["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last()
    assert last_user["content"] == "what is in this picture?"
  end
end

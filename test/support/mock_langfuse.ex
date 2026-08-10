defmodule Pepe.Test.MockLangfuse do
  @moduledoc """
  A tiny stand-in for Langfuse's `GET /api/public/v2/prompts/{promptName}`, for tests.
  Captures the request (path + auth header) so a test can assert on it.

  Any name starting with `chat:` returns a chat-type prompt whose messages are the
  rest of the name, `|`-separated `role=content` pairs (e.g. `chat:system=Hi|user=x`);
  any name starting with `missing` 404s; anything else returns a text-type prompt
  whose template is `"persona for " <> name` - since every test that cares about
  content generates its own unique name (`System.unique_integer/1`), this both
  proves the right name reached the server AND can never collide with another
  test's already-cached entry in Pepe.Store.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    name = conn.path_info |> List.last() |> URI.decode()

    case Process.whereis(__MODULE__.Listener) do
      nil -> :ok
      pid -> send(pid, {:langfuse_request, conn.path_info, get_req_header(conn, "authorization")})
    end

    respond(conn, name)
  end

  defp respond(conn, "missing" <> _), do: json(conn, 404, %{"message" => "not found"})

  defp respond(conn, "chat:" <> spec) do
    messages =
      spec
      |> String.split("|", trim: true)
      |> Enum.map(fn pair ->
        [role, content] = String.split(pair, "=", parts: 2)
        %{"role" => role, "content" => content}
      end)

    json(conn, 200, %{"type" => "chat", "name" => spec, "version" => 1, "prompt" => messages, "config" => %{}, "labels" => [], "tags" => []})
  end

  defp respond(conn, name) do
    json(conn, 200, %{
      "type" => "text",
      "name" => name,
      "version" => 1,
      "prompt" => "persona for " <> name,
      "config" => %{},
      "labels" => [],
      "tags" => []
    })
  end

  defp json(conn, status, body), do: conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))

  def listen, do: Process.register(self(), __MODULE__.Listener)
end

defmodule Pepe.Test.MockOtelCollector do
  @moduledoc """
  A tiny OTLP/HTTP collector for tests: captures the request (headers + decoded JSON
  body) and forwards it to whichever process asked to be notified, so a test can
  `assert_receive` past `Pepe.Otel.export/1`'s fire-and-forget `Task.start`.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    parsed = Jason.decode!(body)

    case Process.whereis(__MODULE__.Listener) do
      nil -> :ok
      pid -> send(pid, {:otel_request, conn.req_headers, parsed})
    end

    conn |> put_resp_content_type("application/json") |> send_resp(200, "{}")
  end

  @doc "Register the calling test process to receive the next captured request."
  def listen do
    Process.register(self(), __MODULE__.Listener)
  end
end

defmodule Pepe.Gateways.TelegramUploadRetryTest do
  @moduledoc """
  A file the agent sends is a POST made right after a long think, which is when the pooled
  connection it picks is one Telegram has already closed. The send used to fail on the first
  `:closed` and report the file undeliverable, with the file sitting there fine. Here the first
  connection is closed the moment it is accepted, as a server does to a stale one, and the
  second answers: the file must arrive.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Gateways.Telegram

  @moduletag :capture_log

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_tg_retry_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    file = Path.join(home, "avatar.png")
    File.write!(file, :crypto.strong_rand_bytes(2_000))

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      Application.delete_env(:pepe, :telegram_api_base)
      File.rm_rf(home)
    end)

    Config.put_telegram(%{"bot_token" => "T", "allowed_chats" => []})
    %{png: file}
  end

  # Closes the first `drops` connections at once, then answers every request with a 200.
  defp serve(drops) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    test = self()

    pid = spawn_link(fn -> accept_loop(listen, drops, test) end)

    Application.put_env(:pepe, :telegram_api_base, "http://127.0.0.1:#{port}")
    on_exit(fn -> Process.unlink(pid) && Process.exit(pid, :kill) end)
  end

  defp accept_loop(listen, drops, test) do
    Enum.each(1..(drops + 1), fn n ->
      {:ok, sock} = :gen_tcp.accept(listen)
      if n <= drops, do: drop(sock, n, test), else: answer(sock, test)
    end)
  end

  defp drop(sock, n, test) do
    :gen_tcp.close(sock)
    send(test, {:dropped, n})
  end

  defp answer(sock, test) do
    drain(sock)
    body = ~s({"ok":true,"result":{"message_id":1}})

    :gen_tcp.send(sock, [
      "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
      body
    ])

    :gen_tcp.close(sock)
    send(test, :answered)
  end

  # Reads until the multipart body is complete enough for the client to stop sending.
  defp drain(sock) do
    case :gen_tcp.recv(sock, 0, 500) do
      {:ok, _data} -> drain(sock)
      {:error, _} -> :ok
    end
  end

  test "a connection closed under the upload is retried and the file arrives", %{png: png} do
    serve(1)

    assert :ok = Telegram.deliver_file("842064390", png, "oi")

    assert_received {:dropped, 1}
    assert_received :answered
  end
end

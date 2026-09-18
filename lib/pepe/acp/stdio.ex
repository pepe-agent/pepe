defmodule Pepe.ACP.Stdio do
  @moduledoc """
  The pipe half of `Pepe.ACP`: one JSON-RPC message per line, stdin in, stdout out.

  An editor starts `pepe acp` as a child process and speaks to it the way it would
  speak to a language server. The framing is simpler than LSP's - no `Content-Length`
  headers, just newline-delimited JSON - and comes with one hard rule from the spec:
  **nothing that is not an ACP message may ever reach stdout.** A stray `IO.puts`, a
  Mix "Compiling 3 files" line, or a single Logger line on the default handler is not
  noise here, it is a protocol violation that desynchronizes the client.

  So `run/1` takes stdout away from everything else before the first message: the
  Logger's default handler is moved to stderr (where an editor happily shows it in an
  agent-log panel), and `Mix.Tasks.Pepe` puts Mix's own shell in quiet mode before it
  compiles. Everything this module writes goes through the one writer below.

  The connection itself is `Pepe.ACP.Server`, which knows nothing about pipes - this
  module owns the bytes and the lifetime, and that is all.
  """

  require Logger

  alias Pepe.ACP.Server

  @doc """
  Serve one ACP connection on stdin/stdout for `agent_name` (nil for the default
  agent) and block until the client closes the pipe.

  Returns `:ok` at EOF, which is how an editor shuts an agent down: it closes stdin
  and expects the process to exit.
  """
  @spec run(String.t() | nil) :: :ok
  def run(agent_name) do
    take_stdout!()

    {:ok, server} = Server.start_link(agent: agent_name, writer: &write_line/1)
    Logger.info("[acp] serving agent #{agent_name || "(default)"} over stdio")

    read_loop(server)
  end

  # One message, one line, no trailing whitespace of our own. `Jason` escapes any
  # newline inside a string, so an encoded message can never contain a raw `\n` and
  # split itself in two on the client's side.
  defp write_line(json), do: IO.binwrite(:standard_io, [json, "\n"])

  defp read_loop(server) do
    case IO.gets(:stdio, "") do
      :eof ->
        drain(server)

      {:error, reason} ->
        Logger.error("[acp] stdin read failed: #{inspect(reason)}")
        drain(server)

      line when is_binary(line) ->
        Server.handle_line(server, line)
        read_loop(server)

      # A non-UTF-8 byte sequence on a protocol that is defined as UTF-8 JSON. Skip
      # the line rather than killing the connection over it.
      other ->
        Logger.warning("[acp] ignoring unreadable stdin line: #{inspect(other)}")
        read_loop(server)
    end
  end

  # Every line already handed to the connection has been written out. `handle_line/2`
  # is a cast, so at EOF there can be messages sitting in the server's mailbox that
  # have not produced their replies yet - and the caller is about to let the VM exit.
  # One synchronous call behind them is enough: it cannot be served until everything
  # queued ahead of it has been.
  defp drain(server) do
    GenServer.call(server, :flush, 5_000)
  catch
    # The connection is already gone, which is the state this was waiting for anyway.
    :exit, _ -> :ok
  end

  # Move the Logger's default handler off stdout, where a single log line is a
  # protocol violation. `:logger_std_h` refuses to change its `type` in place (it is
  # one of the fields it will not accept an update for), so the handler is replaced
  # rather than reconfigured - same module, same level, same formatter, different
  # device.
  #
  # Best-effort on purpose: a release with its own logging setup, or a test harness
  # that swapped the handler out, has nothing here to move, and refusing to start over
  # that would be worse than the log lines this is protecting against.
  defp take_stdout! do
    with {:ok, handler} <- :logger.get_handler_config(:default),
         module when module != nil <- handler[:module],
         config = handler |> Map.drop([:id, :module]) |> Map.update(:config, %{}, &Map.put(&1, :type, :standard_error)),
         :ok <- :logger.remove_handler(:default) do
      :logger.add_handler(:default, module, config)
    end

    :ok
  catch
    _kind, _reason -> :ok
  end
end

defmodule Pepe.Tools.ManagePepe do
  @moduledoc """
  Run the non-interactive `pepe` CLI from a conversation, so a trusted agent can drive
  the whole runtime by chat: add models and agents, manage channels, cron tasks,
  watches, tokens, projects, plugins, hooks, config, usage, and more.

  This is the most powerful tool in the box. Give it **only to an owner-style agent you
  fully trust**, never to a client-facing bot. It is not read-only, so every call goes
  through the permission gate (you authorize it) unless the agent pre-approves it.

  It calls the same dispatcher the `pepe` binary uses, so behaviour is identical to the
  terminal. Two categories are refused because they cannot work as a one-shot call:

    * **Interactive** commands that prompt for input: `setup`, `chat`, `tui`, and
      `gateway telegram setup`.
    * **Blocking** commands that run forever: `serve` and a foreground `gateway`.

  `eval` is also refused because it registers a process-exit handler. For everything
  else the command runs via `Mix.Tasks.Pepe.dispatch_attached/1`, the same dispatch
  the CLI uses, except it never touches the global `serve_endpoint`/`start_gateways`/
  `persist_sessions` app env a fresh CLI process would flip at boot, since this one is
  running *inside* an already-live server, not booting a new one. See that function's
  doc for why that distinction matters.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  # A command that reaches the model or blocks could take a while; cap it so a slipped
  # interactive prompt or a slow run can never hang the conversation.
  @timeout_ms 120_000

  @impl true
  def name, do: "manage_pepe"

  @impl true
  def spec do
    function(
      "manage_pepe",
      """
      Run a pepe CLI command and return its output, exactly as if typed in a terminal. \
      Pass `command` as everything after "pepe" (e.g. "agent list", "model add openai \
      --base-url URL --model gpt-5", "token add --project acme --label ci"). This is a \
      privileged tool, so confirm the exact command with the user before running \
      anything that changes state.

      Refused (they can't run as a one-shot): setup, chat, tui, serve, eval, and the \
      foreground gateway forms (gateway with no subcommand, "gateway telegram", and \
      "gateway telegram setup"). Use `manage_channel` to wire up channels instead. \
      Everything else works: config, dashboard, backup, project, model, agent, token, \
      cron, watch, hooks, plugin, mcp, usage, traces, learn, migrate, doctor, and the \
      non-interactive gateway subcommands. Run "help" to see the full command list.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "The pepe command line without the leading \"pepe\", e.g. \"agent list\" or \"token add --project acme\"."
          }
        },
        "required" => ["command"]
      }
    )
  end

  @impl true
  def run(%{"command" => command}, ctx) do
    cond do
      is_nil(ctx[:agent]) -> {:error, "no calling agent in context"}
      not is_binary(command) -> {:error, "command must be a string"}
      true -> dispatch(argv(command))
    end
  end

  def run(_args, _ctx), do: {:error, "manage_pepe needs a `command`"}

  # Split the command line like a shell, dropping a leading "pepe" if the model included it.
  defp argv(command) do
    case OptionParser.split(command) do
      ["pepe" | rest] -> rest
      other -> other
    end
  end

  defp dispatch(argv) do
    case blocked(argv) do
      {:blocked, what} ->
        {:error,
         "the `#{what}` command is interactive or long-running and can't be run by chat. " <>
           "Do it in a terminal, or use a dedicated tool (e.g. manage_channel for gateways)."}

      :ok ->
        run_captured(argv)
    end
  end

  # Interactive or never-returning commands are refused; everything else runs.
  # `dashboard password` with no value is its own interactive case (a hidden-input
  # prompt), refused for the same reason as `setup`/`chat`/`tui`: there's no real
  # terminal behind this call for it to read from, just a `StringIO` buffer, so it
  # would hit EOF and error instead of prompting.
  defp blocked([first | _]) when first in ~w(setup chat tui serve eval), do: {:blocked, first}
  defp blocked(["gateway"]), do: {:blocked, "gateway"}
  defp blocked(["gateway", "telegram"]), do: {:blocked, "gateway telegram"}
  defp blocked(["gateway", "telegram", "setup" | _]), do: {:blocked, "gateway telegram setup"}
  defp blocked(["dashboard", "password"]), do: {:blocked, "dashboard password (with no value)"}
  defp blocked(_), do: :ok

  defp run_captured(argv) do
    task = Task.async(fn -> capture(argv) end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task) do
      {:ok, output} -> {:ok, present(output)}
      _ -> {:error, "command timed out after #{div(@timeout_ms, 1000)}s (it may be blocking)"}
    end
  end

  # Run the dispatcher with this process's output redirected into a string buffer.
  defp capture(argv) do
    {:ok, buffer} = StringIO.open("")
    Process.group_leader(self(), buffer)

    outcome =
      try do
        Mix.Tasks.Pepe.dispatch_attached(argv)
        nil
      rescue
        e -> "error: #{Exception.message(e)}"
      catch
        kind, value -> "error: #{inspect({kind, value})}"
      end

    {_in, out} = StringIO.contents(buffer)
    StringIO.close(buffer)
    {out, outcome}
  end

  defp present({out, outcome}) do
    text = out |> strip_ansi() |> String.trim()

    [outcome, blank_to_nil(text)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "(no output)"
      parts -> Enum.join(parts, "\n")
    end
  end

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end

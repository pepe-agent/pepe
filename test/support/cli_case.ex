defmodule Pepe.CLICase do
  @moduledoc """
  Case template for the `mix pepe` CLI (`Mix.Tasks.Pepe.dispatch/1`).

  Gives every test a throwaway `PEPE_HOME` (so a command's real effect on the
  config file is observable, and nothing touches the developer's own `~/.pepe`)
  and `run/1`, which dispatches an argv and hands back exactly what a user would
  see: stdout and stderr, ANSI stripped.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Pepe.CLICase
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    # Commands that need the runtime go through `with_app/2`, which rewrites these
    # globals for the whole VM; leaking one would silently reconfigure the app for
    # every test that runs after this file.
    app_env =
      Enum.map(
        [:serve_endpoint, :start_gateways, :persist_sessions],
        &{&1, Application.fetch_env(:pepe, &1)}
      )

    on_exit(fn ->
      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      Enum.each(app_env, &restore_app_env/1)
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp restore_app_env({key, {:ok, value}}), do: Application.put_env(:pepe, key, value)
  defp restore_app_env({key, :error}), do: Application.delete_env(:pepe, key)

  @doc """
  Dispatch `argv` through the CLI and return `{stdout, stderr}`.

  Failures are written to stderr, so a command's error message is only ever
  visible in the second element.
  """
  def run(argv) do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        captured = ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
        Process.put(:cli_stdout, captured)
      end)

    {strip_ansi(Process.get(:cli_stdout)), strip_ansi(stderr)}
  end

  defp strip_ansi(text), do: String.replace(to_string(text), ~r/\e\[[0-9;]*m/, "")
end

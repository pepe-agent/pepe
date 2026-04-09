defmodule Pepe.Gateways.TUIModelTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Agent.Session
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Gateways.TUI

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tui_model_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Model{name: "model-a", base_url: "https://x", model: "gpt-a"})
    Config.put_model(%Model{name: "model-b", base_url: "https://x", model: "gpt-b"})
    Config.put_agent(%Agent{name: "console", model: "model-a"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, key: "tui:test:#{System.unique_integer([:positive])}"}
  end

  # `capture_io` with `:input` feeds each line to the REPL's `IO.gets`; once the
  # input is exhausted, `IO.gets` returns `:eof` and `loop/1` returns naturally -
  # no need for an explicit `/exit`.
  defp run(key, lines) do
    capture_io([input: Enum.join(lines, "\n") <> "\n"], fn ->
      TUI.start("console", key)
    end)
  end

  test "/models lists what's configured", %{key: key} do
    out = run(key, ["/models"])
    assert out =~ "model-a"
    assert out =~ "model-b"
  end

  test "/model with no args shows the current model", %{key: key} do
    out = run(key, ["/model"])
    assert out =~ "gpt-a"
  end

  test "/model NAME with no scope asks to confirm session or global", %{key: key} do
    out = run(key, ["/model model-b"])
    assert out =~ "this conversation only"
    assert Config.get_agent("console").model == "model-a"
  end

  test "/model NAME session overrides only this console's session", %{key: key} do
    out = run(key, ["/model model-b session"])
    assert out =~ "Model set to model-b"
    assert Config.get_agent("console").model == "model-a"
    assert Session.status(key).model == "gpt-b"
  end

  test "/model NAME global persists the change on the agent", %{key: key} do
    out = run(key, ["/model model-b global"])
    assert out =~ "Model set to model-b"
    assert Config.get_agent("console").model == "model-b"
  end

  test "an unknown model name is refused", %{key: key} do
    out = run(key, ["/model ghost"])
    assert out =~ "Unknown model"
    assert Config.get_agent("console").model == "model-a"
  end
end

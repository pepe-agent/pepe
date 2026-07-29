defmodule Mix.Tasks.PepeUsageRunsCliTest do
  @moduledoc """
  `mix pepe usage runs` - the per-message report, and the one figure a per-cycle report
  cannot give: how many model calls one inbound message actually took.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Usage.Log
  alias Pepe.Usage.Runs

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_usage_runs_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    Config.put_model(%Model{name: "mock", base_url: "http://x", api_key: "k", model: "m", input_price: 1.0, output_price: 2.0})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  # One message that took three model calls with two tools between them.
  defp seed(id \\ "1000") do
    at = 1_770_000_000

    Runs.record(%{
      id: id,
      scope: nil,
      at: at,
      agent: "assistant",
      session: "telegram:7",
      source: "telegram",
      ms: 4_210,
      outcome: %{"kind" => "ok"},
      events: [
        %{"t" => "tool_call", "name" => "bash", "args" => "ls"},
        %{"t" => "tool_call", "name" => "read_file", "args" => "a.txt"}
      ]
    })

    for _ <- 1..3 do
      Log.append(nil, %{
        "at" => at,
        "agent" => "assistant",
        "model" => "mock",
        "in" => 10,
        "out" => 5,
        "run_id" => id,
        "source" => "telegram",
        "session" => "telegram:7"
      })
    end
  end

  test "lists one line per message, with its tools and its calls" do
    seed()

    out = pepe(["usage", "runs"])

    assert out =~ "1000"
    assert out =~ "assistant"
    assert out =~ "telegram"
    assert out =~ "bash,read_file"
    assert out =~ "3 calls"
  end

  test "says so plainly when nothing has been recorded" do
    assert pepe(["usage", "runs"]) =~ "no runs recorded yet"
  end

  test "narrows to one source" do
    seed("1000")

    Runs.record(%{
      id: "2000",
      scope: nil,
      at: 1_770_000_100,
      agent: "assistant",
      session: nil,
      source: "api",
      ms: 12,
      outcome: %{"kind" => "ok"},
      events: []
    })

    out = pepe(["usage", "runs", "--source", "api"])

    assert out =~ "2000"
    refute out =~ "1000"
  end

  test "breaks one message down call by call" do
    seed()

    out = pepe(["usage", "runs", "1000"])

    assert out =~ "run 1000"
    assert out =~ "bash → read_file"
    assert out =~ "ok in 4210ms"
    # One line per metered call, three of them, plus a TOTAL that is their sum rather than
    # any one of them.
    assert out |> String.split("mock") |> Enum.drop(1) |> Enum.count() == 3
    assert out =~ "TOTAL"
  end

  test "an unknown run id is an error, not an empty report" do
    assert pepe_err(["usage", "runs", "nope"]) =~ "no run with id nope"
  end

  test "a mistyped --prices is refused rather than quietly narrowed" do
    # `Pepe.ApiToken.price_view/1` coerces anything unknown to "billable", which is the right
    # last resort but the wrong answer to a typo: the operator would be told the token was
    # created while it sees something other than what they asked for.
    assert pepe_err(["token", "add", "--usage", "--prices", "al"]) =~ "--prices must be one of"
    assert Pepe.Config.api_tokens() == []
  end
end

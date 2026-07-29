defmodule Pepe.UsageRunLinkTest do
  @moduledoc """
  The join between the two halves of "what did this message cost": the ledger entries a run
  produced, and the run row that says what the run was doing while it produced them.
  """
  use ExUnit.Case, async: false

  alias Pepe.Trace
  alias Pepe.Usage
  alias Pepe.Usage.Log
  alias Pepe.Usage.Runs

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_run_link_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    File.write!(
      Path.join(home, "config.json"),
      Jason.encode!(%{"agents" => %{"assistant" => %{"model" => "m", "system_prompt" => "hi", "tools" => []}}})
    )

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp usage(n), do: %{"prompt_tokens" => n, "completion_tokens" => n}

  test "every call metered inside a run is stamped with that run" do
    :started = Trace.start("assistant", "telegram:7", "hi", "telegram")

    Usage.record("assistant", "gpt", usage(10))
    Usage.record("assistant", "gpt", usage(20))

    id = Trace.finish({:ok, "done", []})

    entries = Log.entries(nil)
    assert [_, _] = entries
    assert Enum.all?(entries, &(&1["run_id"] == id))
    assert Enum.all?(entries, &(&1["session"] == "telegram:7"))
    assert Enum.all?(entries, &(&1["source"] == "telegram"))

    assert [_, _] = Log.entries_for_run(nil, id)
  end

  test "metering outside a run belongs to no run rather than to the last one" do
    :started = Trace.start("assistant", nil, "hi", "cli")
    Usage.record("assistant", "gpt", usage(10))
    Trace.finish({:ok, "done", []})

    # Background work (session titling, compaction) meters with no trace open.
    Usage.record("assistant", "gpt", usage(99))

    assert [_inside, outside] = Log.entries(nil)
    refute Map.has_key?(outside, "run_id")
  end

  test "finishing a run records what it did, without any of what it said" do
    :started = Trace.start("assistant", "api:1", "list the files", "api")

    Trace.event({:tool_call, "bash", "ls -la"})
    Trace.event({:tool_result, "bash", "a.txt"})
    Trace.event({:tool_call, "read_file", "a.txt"})
    Usage.record("assistant", "gpt", usage(10))

    id = Trace.finish({:ok, "done", []})

    assert [run] = Runs.list(nil)
    assert run["id"] == id
    assert run["tools"] == ["bash", "read_file"]
    assert run["tool_calls"] == 2
    assert run["source"] == "api"
    assert run["session"] == "api:1"
    assert run["outcome"] == "ok"
    assert is_integer(run["ms"])

    # The transcript stays in the trace; the billing-side row carries no content at all.
    refute Map.has_key?(run, "prompt")
    refute run |> Map.values() |> Enum.any?(&(&1 == "list the files"))
  end

  test "a failed run keeps only the outcome's kind, never the reason" do
    :started = Trace.start("assistant", nil, "hi", "cli")
    Trace.finish({:error, {:upstream, "https://internal.example/v1"}})

    assert [run] = Runs.list(nil)
    assert run["outcome"] == "error"
    refute run |> Map.values() |> Enum.any?(&(is_binary(&1) and String.contains?(&1, "internal.example")))
  end

  test "a nested sub-agent run folds into the message that started it" do
    :started = Trace.start("assistant", nil, "hi", "cli")
    assert Trace.start("assistant", nil, "sub", "cli") == :nested

    Usage.record("assistant", "gpt", usage(10))
    id = Trace.finish({:ok, "done", []})

    # One message, one run row - not one per agent that worked on it.
    assert [run] = Runs.list(nil)
    assert run["id"] == id
    assert [_only] = Log.entries_for_run(nil, id)
  end
end

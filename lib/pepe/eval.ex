defmodule Pepe.Eval do
  @moduledoc """
  A tiny eval harness: replay recorded prompts through an agent and assert on the reply
  and the tools it called, so you catch regressions when you change a prompt, model or
  toolset. Suites are JSON files in `PEPE_HOME/evals/<suite>.json`, each a list of cases:

      [
        {
          "name": "greets",
          "agent": "assistant",
          "prompt": "say hi",
          "expect": {
            "contains": ["hi"],             // reply includes each (case-insensitive)
            "not_contains": ["error"],      // reply includes none of these
            "matches": "hi|hello",          // reply matches this regex
            "tool_called": ["web_search"],  // these tools ran during the turn
            "tool_not_called": ["bash"]     // these tools did not run
          }
        }
      ]

  Every `expect` key is optional; a case passes when all present assertions hold. Run with
  `mix pepe eval [suite]`.
  """
  alias Pepe.Config

  @type result :: %{
          name: String.t(),
          agent: String.t() | nil,
          passed: boolean(),
          reply: String.t(),
          tools: [String.t()],
          failures: [String.t()]
        }

  @doc "Directory holding the user's eval suites (these override bundled ones by name)."
  def dir, do: Path.join(Config.home(), "evals")

  @doc "Directory holding the suites shipped with Pepe."
  def bundled_dir, do: Application.app_dir(:pepe, "priv/evals")

  @doc """
  Names of the available suites (the `.json` basenames), from both the user directory
  and the bundled set. A user suite shadows a bundled one with the same name.
  """
  def suites do
    (names_in(dir()) ++ names_in(bundled_dir()))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp names_in(directory) do
    case File.ls(directory) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.rootname/1)

      _ ->
        []
    end
  end

  @doc """
  Load a suite's cases (a list of maps). Looks in the user directory first, then the
  bundled set. Returns `[]` when missing or invalid.
  """
  def load(suite) do
    read_cases(Path.join(dir(), suite <> ".json")) ||
      read_cases(Path.join(bundled_dir(), suite <> ".json")) ||
      []
  end

  defp read_cases(path) do
    with {:ok, body} <- File.read(path),
         {:ok, cases} when is_list(cases) <- Jason.decode(body) do
      cases
    else
      _ -> nil
    end
  end

  @doc """
  Copy every bundled suite into the user directory (skipping ones already there), so they
  can be edited. Returns the list of suite names written.
  """
  def seed do
    File.mkdir_p!(dir())

    for name <- names_in(bundled_dir()),
        dest = Path.join(dir(), name <> ".json"),
        not File.exists?(dest) do
      File.cp!(Path.join(bundled_dir(), name <> ".json"), dest)
      name
    end
  end

  @doc "Run every case in a suite."
  @spec run_suite(String.t(), keyword()) :: [result()]
  def run_suite(suite, opts \\ []), do: Enum.map(load(suite), &run_case(&1, opts))

  @doc "Run one case: fresh agent turn, collect the reply and the tools it called, assert."
  @spec run_case(map(), keyword()) :: result()
  def run_case(c, opts \\ []) when is_map(c) do
    {:ok, collector} = Agent.start_link(fn -> [] end)

    on_event = fn
      {:tool_call, name, _args} -> Agent.update(collector, &[name | &1])
      _ -> :ok
    end

    run_opts = opts |> Keyword.put(:on_event, on_event) |> Keyword.put_new(:source, "eval")

    reply =
      case Pepe.Agent.oneshot(c["agent"], c["prompt"] || "", run_opts) do
        {:ok, content, _msgs} -> to_string(content)
        {:error, reason} -> "ERROR: #{inspect(reason)}"
      end

    tools = Agent.get(collector, &Enum.reverse/1)
    Agent.stop(collector)

    failures = evaluate(c["expect"] || %{}, reply, tools)

    %{
      name: c["name"] || c["prompt"] || "case",
      agent: c["agent"],
      passed: failures == [],
      reply: reply,
      tools: tools,
      failures: failures
    }
  end

  @doc """
  Evaluate an `expect` map against a `reply` and the list of `tools` that ran. Returns the
  list of human-readable failures (empty means the case passed). Pure, so it's easy to test.
  """
  @spec evaluate(map(), String.t(), [String.t()]) :: [String.t()]
  def evaluate(expect, reply, tools) when is_map(expect) do
    down = String.downcase(reply)

    []
    |> add(for s <- wrap(expect["contains"]), not String.contains?(down, String.downcase(s)), do: "reply is missing #{inspect(s)}")
    |> add(for s <- wrap(expect["not_contains"]), String.contains?(down, String.downcase(s)), do: "reply should not contain #{inspect(s)}")
    |> add(matches_fail(expect["matches"], reply))
    |> add(for name <- wrap(expect["tool_called"]), name not in tools, do: "tool #{name} was not called")
    |> add(for name <- wrap(expect["tool_not_called"]), name in tools, do: "tool #{name} should not have been called")
  end

  defp matches_fail(nil, _reply), do: []

  # Compile unicode-aware ("u") so `.` and classes span whole code points, not bytes -
  # otherwise a multi-byte char (a typographic apostrophe, an accent) breaks the match.
  defp matches_fail(pattern, reply) do
    case Regex.compile(pattern, "u") do
      {:ok, re} -> if Regex.match?(re, reply), do: [], else: ["reply doesn't match /#{pattern}/"]
      _ -> ["invalid regex /#{pattern}/"]
    end
  end

  defp add(list, msgs), do: list ++ List.wrap(msgs)

  defp wrap(nil), do: []
  defp wrap(v) when is_list(v), do: v
  defp wrap(v), do: [v]
end

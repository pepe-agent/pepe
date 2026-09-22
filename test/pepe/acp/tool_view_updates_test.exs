defmodule Pepe.ACP.ToolViewUpdatesTest do
  @moduledoc """
  The presentation half of the editor surface: how a tool call reads in an editor
  (`Pepe.ACP.ToolView`) and the `session/update` payloads that are not message text
  (`Pepe.ACP.Updates`). Both are pure, so the wire shapes are pinned directly.
  """
  use ExUnit.Case, async: false

  alias Pepe.ACP.ToolView
  alias Pepe.ACP.Updates
  alias Pepe.Config
  alias Pepe.Config.Model

  describe "ToolView.kind/1" do
    test "classifies the tools Pepe ships and calls everything else `other`" do
      assert ToolView.kind("read_file") == "read"
      assert ToolView.kind("write_file") == "edit"
      assert ToolView.kind("edit_file") == "edit"
      assert ToolView.kind("move_file") == "move"
      assert ToolView.kind("bash") == "execute"
      assert ToolView.kind("fetch_url") == "fetch"
      assert ToolView.kind("web_search") == "search"
      assert ToolView.kind("update_plan") == "think"
      assert ToolView.kind("mcp__editor_probe__probe") == "other"
      assert ToolView.kind("a_plugin_tool") == "other"
    end
  end

  describe "ToolView.title/2" do
    test "says what is happening, by the argument that says the most" do
      assert ToolView.title("read_file", %{"path" => "lib/pepe.ex"}) == "read_file: lib/pepe.ex"
      assert ToolView.title("bash", %{"command" => "mix test"}) == "bash: mix test"
      assert ToolView.title("fetch_url", %{"url" => "https://example.com"}) == "fetch_url: https://example.com"
      assert ToolView.title("move_file", %{"from" => "a", "to" => "b"}) == "move_file: a -> b"
    end

    test "is the bare tool name when the arguments say nothing" do
      assert ToolView.title("bash", %{}) == "bash"
      assert ToolView.title("bash", %{"command" => ""}) == "bash"
      assert ToolView.title("bash", "not a map") == "bash"
    end

    test "keeps to one short line" do
      title = ToolView.title("bash", %{"command" => String.duplicate("x", 200) <> "\nsecond line"})

      assert String.length(title) <= String.length("bash: ") + 80
      assert String.ends_with?(title, "...")
      refute title =~ "\n"
    end
  end

  describe "ToolView.locations/3" do
    test "gives the files a call touches as absolute paths" do
      assert ToolView.locations("read_file", %{"path" => "lib/a.ex"}, "/work") == [%{"path" => "/work/lib/a.ex"}]
      assert ToolView.locations("write_file", %{"path" => "/etc/x"}, "/work") == [%{"path" => "/etc/x"}]
    end

    test "read_file's offset is the line it starts from, and a bad one is ignored" do
      assert ToolView.locations("read_file", %{"path" => "a", "offset" => 12}, "/w") == [%{"path" => "/w/a", "line" => 12}]
      assert ToolView.locations("read_file", %{"path" => "a", "offset" => 0}, "/w") == [%{"path" => "/w/a"}]
    end

    test "a move names both ends, and other tools name nothing" do
      assert ToolView.locations("move_file", %{"from" => "a", "to" => "b"}, "/w") == [%{"path" => "/w/a"}, %{"path" => "/w/b"}]
      assert ToolView.locations("bash", %{"command" => "ls"}, "/w") == []
      assert ToolView.locations("read_file", %{"path" => ""}, "/w") == []
    end
  end

  describe "ToolView.result_content/1 and failed?/1" do
    test "wraps output as one text block" do
      assert [%{"type" => "content", "content" => %{"type" => "text", "text" => "hi"}}] = ToolView.result_content("hi")
    end

    test "caps a huge result and says how much was cut" do
      [%{"content" => %{"text" => text}}] = ToolView.result_content(String.duplicate("a", 25_000))

      assert String.length(text) < 25_000
      assert text =~ "5000 more characters not shown"
    end

    test "a result reads as failed by Pepe's own `Error: ` convention" do
      assert ToolView.failed?("Error: tool bash crashed")
      refute ToolView.failed?("fine")
      refute ToolView.failed?(nil)
    end
  end

  describe "Updates.plan/1" do
    test "maps the plan tool's steps onto ACP plan entries, replacing the whole plan" do
      steps = [
        %{"title" => "Read the code", "status" => "done"},
        %{"title" => "Write the fix", "status" => "in_progress"},
        %{"title" => "Test it"}
      ]

      assert %{"sessionUpdate" => "plan", "entries" => [first, second, third]} = Updates.plan(steps)
      assert first == %{"content" => "Read the code", "priority" => "medium", "status" => "completed"}
      assert second["status"] == "in_progress"
      assert third["status"] == "pending"
    end

    test "an empty plan clears the panel" do
      assert %{"entries" => []} = Updates.plan([])
    end
  end

  describe "Updates.usage/2" do
    setup do
      home = Path.join(System.tmp_dir!(), "pepe_acp_updates_#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      prev = System.get_env("PEPE_HOME")
      System.put_env("PEPE_HOME", home)
      Pepe.RepoSetup.start!()

      on_exit(fn ->
        if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
        File.rm_rf(home)
      end)

      Config.put_model(%Model{name: "sized", base_url: "http://localhost:1", api_key: "k", model: "m", context_window: 8_000})
      :ok
    end

    test "reports the prompt plus the answer as `used`, against the model's window" do
      usage = %{"prompt_tokens" => 1_000, "completion_tokens" => 200}

      assert %{"sessionUpdate" => "usage_update", "used" => 1_200, "size" => 8_000} = Updates.usage("sized", usage)
    end

    test "falls back to the provider's total, and says nothing when nothing was measured" do
      assert %{"used" => 500} = Updates.usage("sized", %{"total_tokens" => 500})
      assert Updates.usage("sized", %{}) == nil
      assert Updates.usage("sized", %{"prompt_tokens" => 0}) == nil
    end

    test "says nothing for a model that is not configured" do
      assert Updates.usage("ghost", %{"prompt_tokens" => 10}) == nil
      assert Updates.usage(nil, %{"prompt_tokens" => 10}) == nil
      assert Updates.usage("sized", :not_a_map) == nil
    end
  end

  describe "turn token accounting" do
    test "tokens/1 reads the usual shapes, including cached tokens in either place" do
      assert Updates.tokens(%{"prompt_tokens" => 10, "completion_tokens" => 5}) == %{input: 10, output: 5, cached: 0}
      assert Updates.tokens(%{"prompt_tokens" => 10, "completion_tokens" => 5, "cached_tokens" => 4}).cached == 4

      nested = %{"prompt_tokens" => 10, "completion_tokens" => 5, "prompt_tokens_details" => %{"cached_tokens" => 7}}
      assert Updates.tokens(nested).cached == 7
      assert Updates.tokens(%{"total_tokens" => 42}) == %{input: 42, output: 0, cached: 0}
      assert Updates.tokens(%{"prompt_tokens" => 1.6}).input == 2
    end

    test "prompt_usage/1 is the PromptResponse usage object, or nothing to report" do
      assert Updates.prompt_usage(%{input: 10, output: 5, cached: 0}) ==
               %{"inputTokens" => 10, "outputTokens" => 5, "totalTokens" => 15}

      assert Updates.prompt_usage(%{input: 10, output: 5, cached: 3})["cachedReadTokens"] == 3
      assert Updates.prompt_usage(%{input: 0, output: 0, cached: 0}) == nil
    end
  end

  describe "the other update payloads" do
    test "available_commands carries every command the agent handles itself" do
      assert %{"sessionUpdate" => "available_commands_update", "availableCommands" => commands} = Updates.available_commands()
      names = Enum.map(commands, & &1["name"])

      for name <- ~w(help new undo rewind compact status model models tools usage steer queue), do: assert(name in names)
      assert %{"input" => %{"hint" => _}} = Enum.find(commands, &(&1["name"] == "rewind"))
      refute Map.has_key?(Enum.find(commands, &(&1["name"] == "help")), "input")
    end

    test "user_message, current_mode and config_options" do
      assert Updates.user_message("next") == %{"sessionUpdate" => "user_message_chunk", "content" => %{"type" => "text", "text" => "next"}}
      assert Updates.current_mode("accept_edits") == %{"sessionUpdate" => "current_mode_update", "currentModeId" => "accept_edits"}

      assert Updates.config_options([%{"id" => "mode"}]) == %{
               "sessionUpdate" => "config_option_update",
               "configOptions" => [%{"id" => "mode"}]
             }
    end
  end
end

defmodule Pepe.Agent.SessionTitlesTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.SessionTitles
  alias Pepe.Config.Agent

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_titles_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "get is nil until set, then returns the label" do
    assert SessionTitles.get("web:1") == nil
    assert SessionTitles.set("web:1", "  My chat  ") == :ok
    assert SessionTitles.get("web:1") == "My chat"
  end

  test "a blank title clears the label" do
    SessionTitles.set("web:2", "temp")
    SessionTitles.set("web:2", "   ")
    assert SessionTitles.get("web:2") == nil
  end

  test "delete forgets one key without touching others" do
    SessionTitles.set("web:3", "keep")
    SessionTitles.set("web:4", "drop")
    SessionTitles.delete("web:4")

    assert SessionTitles.get("web:3") == "keep"
    assert SessionTitles.get("web:4") == nil
  end

  test "titles survive being read back from disk (persisted, not in-memory)" do
    SessionTitles.set("web:5", "persisted")
    assert SessionTitles.all()["web:5"] == "persisted"
  end

  # generate/5's no-model (trim) path - the model-based PENDING verdict is covered end to
  # end in Pepe.Agent.AutoTitleTest, which has the mock LLM this path skips entirely.
  describe "generate/5 without a utility model" do
    defp agent, do: %Agent{name: "a", system_prompt: "x", utility_model: nil}

    test "defers when the message itself reads too thin" do
      assert SessionTitles.generate("web:thin", agent(), "oi", "oi") == :skip
      assert SessionTitles.get("web:thin") == nil
    end

    test "force? accepts a thin candidate instead of deferring forever" do
      assert SessionTitles.generate("web:thin-forced", agent(), "oi", "oi", true) == {:ok, "oi"}
    end

    test "the reply is never the trim source, however much longer it is than the message" do
      # A heuristic can't tell a genuinely short topic from an assistant's own filler reply -
      # so this path doesn't try, and only ever trims the message itself.
      assert SessionTitles.generate("web:reply-ignored", agent(), "oi", "vamos configurar o servidor de producao") ==
               :skip

      assert SessionTitles.generate("web:reply-ignored-2", agent(), "docker deploy question", "sure, here you go") ==
               {:ok, "docker deploy question"}
    end

    test "a greeting-shaped reply of several words still doesn't become the title" do
      # The exact regression an earlier version of this fix introduced: "oi" -> "Olá! Como
      # posso te ajudar hoje?" is 6 words, well past a naive word-count floor, but it's still
      # just small talk, not a topic.
      assert SessionTitles.generate("web:greeting-reply", agent(), "oi", "Olá! Como posso te ajudar hoje?") == :skip
    end

    test "a title set while naming was computed (a human rename mid-flight) is never clobbered" do
      key = "web:race"
      # Simulates the exact race: get(key) is nil when generate/5 is first called (checked
      # at its own top), but by the time it's ready to store, a human's rename has already
      # landed - the write at the end must re-check, not trust the check from the start.
      SessionTitles.set(key, "Human's own title")
      assert SessionTitles.generate(key, agent(), "docker deploy question") == :skip
      assert SessionTitles.get(key) == "Human's own title"
    end
  end
end

defmodule Pepe.Agent.SessionTitlesTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.SessionTitles

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
end

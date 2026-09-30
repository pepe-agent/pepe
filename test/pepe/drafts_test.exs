defmodule Pepe.DraftsTest do
  use ExUnit.Case, async: false

  alias Pepe.Drafts

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_drafts_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "there is no draft until one is put" do
    assert Drafts.get("agent", "default/pesado") == nil
  end

  test "put stores the data, and put again replaces it (one draft per record)" do
    :ok = Drafts.put("agent", "default/pesado", %{"system_prompt" => "one", "tools" => ["bash"]})
    assert %{data: %{"system_prompt" => "one", "tools" => ["bash"]}, updated_at: at} = Drafts.get("agent", "default/pesado")
    assert is_integer(at)

    :ok = Drafts.put("agent", "default/pesado", %{"system_prompt" => "two"})
    assert %{data: %{"system_prompt" => "two"}} = Drafts.get("agent", "default/pesado")
    assert Drafts.keys("agent") == ["default/pesado"]
  end

  test "drafts are separate per kind and per key" do
    Drafts.put("agent", "a", %{"n" => 1})
    Drafts.put("agent", "b", %{"n" => 2})
    Drafts.put("model", "a", %{"n" => 3})

    assert %{data: %{"n" => 1}} = Drafts.get("agent", "a")
    assert %{data: %{"n" => 3}} = Drafts.get("model", "a")
    assert Enum.sort(Drafts.keys("agent")) == ["a", "b"]
    assert Drafts.keys("model") == ["a"]
  end

  test "delete drops one draft and is a no-op when there is none" do
    Drafts.put("agent", "a", %{"n" => 1})
    Drafts.put("agent", "b", %{"n" => 2})

    assert Drafts.delete("agent", "a") == :ok
    assert Drafts.get("agent", "a") == nil
    assert %{data: %{"n" => 2}} = Drafts.get("agent", "b")
    assert Drafts.delete("agent", "never-existed") == :ok
  end
end

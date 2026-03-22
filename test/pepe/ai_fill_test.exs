defmodule PepeWeb.AiFillTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Config
  alias Pepe.Config.Model
  alias PepeWeb.AiFill

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_aifill_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Config.put_model(%Model{name: "m", base_url: "http://x/v1", model: "m"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  describe "state helpers" do
    test "toggle opens for a field and closes when reopened; put stores a value" do
      ai = AiFill.init()
      assert ai.open == nil

      ai = AiFill.toggle(ai, "cron[schedule_custom]", "cron", "hint")
      assert ai.open == "cron[schedule_custom]"
      assert ai.kind == "cron"
      assert ai.placeholder == "hint"

      assert AiFill.toggle(ai, "cron[schedule_custom]", "cron").open == nil

      ai = AiFill.busy(ai)
      assert ai.busy
      ai = AiFill.put(ai, "cron[schedule_custom]", "0 9 * * 1")
      refute ai.busy
      assert ai.open == nil
      assert AiFill.value(ai, "cron[schedule_custom]") == "0 9 * * 1"
      assert AiFill.value(ai, "other", "fallback") == "fallback"
    end
  end

  describe "generate/3 (cron)" do
    test "returns a validated cron expression" do
      Mimic.stub(Pepe.LLM, :chat, fn _m, _msgs, _o -> {:ok, %{content: "0 9 * * 1-5"}} end)
      assert {:ok, "0 9 * * 1-5"} = AiFill.generate("cron", "every weekday at 9", "m")
    end

    test "rejects an invalid expression the model returns" do
      Mimic.stub(Pepe.LLM, :chat, fn _m, _msgs, _o -> {:ok, %{content: "not a cron"}} end)
      assert {:error, _} = AiFill.generate("cron", "gibberish", "m")
    end
  end

  describe "generate/3 (pii_pattern)" do
    test "returns a name|pattern|LABEL line from a validated pattern" do
      json = ~s({"name":"crm","pattern":"CRM-\\\\d+","replace":"[CRM]"})
      Mimic.stub(Pepe.LLM, :chat, fn _m, _msgs, _o -> {:ok, %{content: json}} end)

      assert {:ok, line} = AiFill.generate("pii_pattern", "hide CRM numbers", "m")
      assert line == "crm|CRM-\\d+|[CRM]"
    end

    test "rejects an invalid regex" do
      json = ~s({"name":"bad","pattern":"([oops","replace":"[X]"})
      Mimic.stub(Pepe.LLM, :chat, fn _m, _msgs, _o -> {:ok, %{content: json}} end)
      assert {:error, _} = AiFill.generate("pii_pattern", "x", "m")
    end
  end

  test "generate/3 with an unknown kind errors" do
    assert {:error, :unknown_kind} = AiFill.generate("nope", "x", "m")
  end

  test "generate/3 with an unknown model errors" do
    Mimic.stub(Pepe.LLM, :chat, fn _m, _msgs, _o -> {:ok, %{content: "0 8 * * *"}} end)
    assert {:error, :unknown_model} = AiFill.generate("cron", "x", "does-not-exist")
  end
end

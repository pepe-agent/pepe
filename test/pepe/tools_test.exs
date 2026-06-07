defmodule Pepe.ToolsTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Tools

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tools_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  describe "finalize scrubs an exposed vault token from tool output" do
    test "an exposed token's value is redacted before it can reach the model or disk" do
      # The one credential deliberately left in the agent's shell (secrets.expose_env) must not
      # ride back out inside a tool result - a stray `env`/`op read`/verbose error would leak it.
      Config.save(%{"secrets" => %{"expose_env" => ["OP_SERVICE_ACCOUNT_TOKEN"]}})
      System.put_env("OP_SERVICE_ACCOUNT_TOKEN", "ops_abcdefghijklmnop1234567890")
      on_exit(fn -> System.delete_env("OP_SERVICE_ACCOUNT_TOKEN") end)

      raw = "OP_SERVICE_ACCOUNT_TOKEN=ops_abcdefghijklmnop1234567890\nPATH=/usr/bin"
      out = Tools.finalize(raw, "bash", %{})

      refute out =~ "ops_abcdefghijklmnop1234567890"
      assert out =~ "«redacted vault token»"
      # Ordinary output is untouched.
      assert out =~ "PATH=/usr/bin"
    end

    test "nothing is exposed by default, so output passes through unchanged" do
      out = Tools.finalize("plain output, no secrets here", "bash", %{})
      assert out == "plain output, no secrets here"
    end

    test "a short exposed value is left alone, so it cannot mangle ordinary output" do
      # A 12-char floor keeps a short, low-entropy exposed value from matching common substrings.
      Config.save(%{"secrets" => %{"expose_env" => ["SHORT"]}})
      System.put_env("SHORT", "abc")
      on_exit(fn -> System.delete_env("SHORT") end)

      out = Tools.finalize("the alphabet abc def", "bash", %{})
      assert out == "the alphabet abc def"
    end
  end
end

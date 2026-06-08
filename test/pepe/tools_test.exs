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
      assert out =~ "«redacted secret»"
      # Ordinary output is untouched.
      assert out =~ "PATH=/usr/bin"
    end

    test "a `${VAR}` model key that Pepe references is redacted too, not just exposed tokens" do
      # Pepe knows this value (the config points at it), so its exact value is scrubbed from
      # output even though it was never in expose_env.
      Config.save(%{
        "models" => %{"m" => %{"base_url" => "https://x/v1", "model" => "g", "api_key" => "${MODEL_KEY}"}}
      })

      System.put_env("MODEL_KEY", "sk-referenced-key-abcdef123456")
      on_exit(fn -> System.delete_env("MODEL_KEY") end)

      out = Tools.finalize("leaked: sk-referenced-key-abcdef123456", "bash", %{})
      refute out =~ "sk-referenced-key-abcdef123456"
      assert out =~ "«redacted secret»"
    end

    test "nothing known and nothing secret-shaped, so output passes through unchanged" do
      out = Tools.finalize("plain output, all fine here", "bash", %{})
      assert out == "plain output, all fine here"
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

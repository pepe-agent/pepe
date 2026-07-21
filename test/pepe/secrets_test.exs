defmodule Pepe.SecretsTest do
  @moduledoc """
  A token pasted into a chat is already leaked, and the write is not what leaks it.

  Pepe used to refuse to save an MCP server when it saw a raw-looking token. It felt
  responsible, and it did nothing: by then the token had been through a model provider and
  was sitting in the transcript and the trace. The refusal did not un-leak it, it only left
  the person stuck. So now the write goes through and the truth is told, and `pepe doctor`
  keeps telling it for anyone who did not read.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Doctor
  alias Pepe.Secrets
  alias Pepe.Tools.ManageMcp

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_sec_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    agent = %Agent{name: "ops", model: "m", system_prompt: "hi", tools: ["manage_mcp"]}
    Config.put_agent(agent)

    %{ctx: %{agent: agent}}
  end

  describe "adding an MCP server with the token pasted in" do
    test "it is saved, not refused", %{ctx: ctx} do
      assert {:ok, out} =
               ManageMcp.run(
                 %{
                   "action" => "add",
                   "name" => "github",
                   "command" => "npx",
                   "args" => ["-y", "@modelcontextprotocol/server-github"],
                   "env" => %{"GITHUB_TOKEN" => "ghp" <> "_1234567890abcdefghijklmnopqrstuvwxyz"}
                 },
                 ctx
               )

      # The thing the user asked for happened. Refusing would not have made the token any
      # less compromised; it would only have left them without an MCP server.
      assert out =~ "saved"
      assert Config.mcp_server("github").env["GITHUB_TOKEN"] =~ "ghp_"
    end

    test "and the answer says what actually has to happen now", %{ctx: ctx} do
      assert {:ok, out} =
               ManageMcp.run(
                 %{
                   "action" => "add",
                   "name" => "github",
                   "command" => "npx",
                   "args" => [],
                   "env" => %{"GITHUB_TOKEN" => "ghp" <> "_1234567890abcdefghijklmnopqrstuvwxyz"}
                 },
                 ctx
               )

      assert out =~ "GITHUB_TOKEN"
      assert out =~ "revoked and reissued"

      # The uncomfortable part, which is also the actionable one.
      assert out =~ "model provider"

      # And the way out, named concretely enough to follow.
      assert out =~ "${GITHUB_TOKEN}"

      # The warning does not reprint the secret. A warning that copies the token somewhere
      # new has made the problem slightly worse while sounding helpful.
      refute out =~ "1234567890abcdefghijklmnopqrstuvwxyz"
      assert out =~ "ghp_"
    end

    test "a token hidden in the args, where it has no key name to give it away, is caught too", %{ctx: ctx} do
      assert {:ok, out} =
               ManageMcp.run(
                 %{
                   "action" => "add",
                   "name" => "thing",
                   "command" => "npx",
                   "args" => ["--token", "sk" <> "-abcdefghijklmnopqrstuvwxyz123456"]
                 },
                 ctx
               )

      assert out =~ "saved"
      assert out =~ "revoked"
    end

    test "an ${ENV_VAR} reference is what we asked for, and is not nagged about", %{ctx: ctx} do
      assert {:ok, out} =
               ManageMcp.run(
                 %{
                   "action" => "add",
                   "name" => "github",
                   "command" => "npx",
                   "args" => [],
                   "env" => %{"GITHUB_TOKEN" => "${GITHUB_TOKEN}"}
                 },
                 ctx
               )

      assert out =~ "saved"
      refute out =~ "revoke"
    end
  end

  describe "pepe doctor" do
    test "finds the token in an MCP env, which it used to walk straight past" do
      Config.put_mcp_server("github", %{
        "command" => "npx",
        "args" => [],
        "env" => %{"GITHUB_TOKEN" => "ghp" <> "_1234567890abcdefghijklmnopqrstuvwxyz"}
      })

      finding =
        Doctor.checks()
        |> Enum.find(fn {area, subject, _} -> area == "security" and subject =~ "GITHUB_TOKEN" end)

      # The old check matched key names *exactly* against a fixed list, so `api_key` was found
      # and `GITHUB_TOKEN` was not - and an MCP token is never called `api_key`.
      assert {_, subject, {:warn, why}} = finding
      assert subject =~ "mcp.github.env.GITHUB_TOKEN"
      assert why =~ "revoke"
    end

    test "says nothing about a reference" do
      Config.put_mcp_server("github", %{
        "command" => "npx",
        "args" => [],
        "env" => %{"GITHUB_TOKEN" => "${GITHUB_TOKEN}"}
      })

      refute Enum.any?(Doctor.checks(), fn {area, subject, _} ->
               area == "security" and subject =~ "GITHUB_TOKEN"
             end)
    end
  end

  describe "what counts as a secret" do
    test "a key name that says so, on word parts rather than exact match" do
      assert Secrets.secret_key?("GITHUB_TOKEN")
      assert Secrets.secret_key?("BRAVE_API_KEY")
      assert Secrets.secret_key?("api_key")

      # A check that cries wolf gets ignored, and then it protects nothing.
      refute Secrets.secret_key?("monkey")
      refute Secrets.secret_key?("model")
      refute Secrets.secret_key?("base_url")
    end

    test "a value that is unmistakably a credential, whatever it was filed under" do
      # Assembled rather than written out, and the reason is worth keeping: a literal that
      # looks like a real provider token trips GitHub's push protection and the whole repo
      # stops being pushable. Which is a fair demonstration of the thing being tested here.
      assert Secrets.plaintext?("ghp" <> "_1234567890abcdefghijklmnopqrst")
      assert Secrets.plaintext?("sk" <> "-abcdefghijklmnopqrstuvwxyz123456")
      assert Secrets.plaintext?("xoxb" <> "-1234567890-abcdefghijklmnop")

      refute Secrets.plaintext?("${GITHUB_TOKEN}")
      refute Secrets.plaintext?("npx")
      refute Secrets.plaintext?("gpt-5-chat")
      refute Secrets.plaintext?("-y")
    end

    # Regression: found on a real production install - an MCP server's `command` pointing at a
    # launcher script was long enough, and made only of the characters the opaque-run pattern
    # matches (letters, digits, `/`, `.`, `-`), to look exactly as "credential-shaped" as a real
    # token. A real credential never starts with `/`; an absolute path always does.
    test "a long absolute path is not credential-shaped, even past the length threshold" do
      refute Secrets.plaintext?("/data/projects/default/agents/admin/scripts/github-mcp.sh")
      refute Secrets.plaintext?("/Users/jhonathas/.pepe/data/projects/default/agents/x/scripts/y.sh")

      # A real credential still is, path-shaped characters or not.
      assert Secrets.plaintext?("sk" <> "-abcdefghijklmnopqrstuvwxyz123456")
    end

    test "masking shows which token it is without handing it over again" do
      masked = Secrets.mask("ghp" <> "_1234567890abcdefghijklmnopqrstuvwxyz")

      assert masked =~ "ghp_"
      refute masked =~ "1234567890"
    end
  end
end

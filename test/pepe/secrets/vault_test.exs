defmodule Pepe.Secrets.VaultTest do
  @moduledoc """
  Two things, and they are independent.

  **The secret can live in a vault.** A config value may say where a secret is instead of
  holding it, and the runtime fetches it at the point of use. The contract is a command that
  prints the secret on stdout, so every vault with a CLI works and Pepe knows the name of
  none of them.

  **And the agent cannot read Pepe's secrets.** `System.cmd` hands a child the parent's whole
  environment, so `echo $OPENAI_API_KEY` in the agent's shell used to return the key. The
  `${ENV_VAR}` scheme kept secrets out of the config *file* and left them sitting in the
  *process* the agent's shell is a child of.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Sandbox
  alias Pepe.Secrets.Vault

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_vault_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Vault.flush()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      System.delete_env("PEPE_TEST_KEY")
      System.delete_env("PEPE_TEST_VAULT_TOKEN")
      Vault.flush()
      File.rm_rf(home)
    end)

    %{home: home}
  end

  describe "a secret can live in a vault" do
    test "a command that prints it is all Pepe needs to know about your vault" do
      # This stands for `op read`, `vault kv get`, `aws secretsmanager get-secret-value`, or
      # a script you wrote this morning. Pepe cannot tell them apart, and does not try.
      Config.put_model(%Model{
        name: "m",
        base_url: "https://x/v1",
        model: "gpt",
        api_key: "exec:printf 'sk-from-the-vault'"
      })

      assert Model.resolved_api_key(Config.get_model("m")) == "sk-from-the-vault"
    end

    test "a file works too, which is what a Docker or Kubernetes secret mount is", %{home: home} do
      path = Path.join(home, "openai_key")
      File.write!(path, "sk-from-the-mount\n")

      Config.put_model(%Model{name: "m", base_url: "https://x/v1", model: "gpt", api_key: "file:" <> path})

      # Trailing newline trimmed: every tool that writes a secret to a file adds one, and a
      # key with a newline on the end is a 401 nobody can explain.
      assert Model.resolved_api_key(Config.get_model("m")) == "sk-from-the-mount"
    end

    test "the environment variable keeps working exactly as before" do
      System.put_env("PEPE_TEST_KEY", "sk-from-the-env")
      Config.put_model(%Model{name: "m", base_url: "https://x/v1", model: "gpt", api_key: "${PEPE_TEST_KEY}"})

      # The whole point of adding vaults is to add them. Nobody's install changes.
      assert Model.resolved_api_key(Config.get_model("m")) == "sk-from-the-env"
    end

    test "a locked vault is an unset secret, never a wrong one" do
      Config.put_model(%Model{name: "m", base_url: "https://x/v1", model: "gpt", api_key: "exec:exit 1"})

      # nil, and the caller treats it exactly as it already treats an unset variable. Half a
      # secret, or an error message where a key should be, would be an authentication failure
      # nobody could explain.
      assert Model.resolved_api_key(Config.get_model("m")) == nil
    end

    test "the resolver is handed only what the operator said it needs" do
      System.put_env("PEPE_TEST_VAULT_TOKEN", "service-account-token")
      System.put_env("PEPE_TEST_KEY", "some-other-secret")

      # A vault CLI usually needs a token of its own to open the vault. The operator names it,
      # and Pepe passes it through without knowing what it is for.
      Config.load()
      |> Map.put("secrets", %{"vault_env" => ["PEPE_TEST_VAULT_TOKEN"]})
      |> Config.save()

      Config.put_model(%Model{
        name: "m",
        base_url: "https://x/v1",
        model: "gpt",
        api_key: "exec:printf \"$PEPE_TEST_VAULT_TOKEN/$PEPE_TEST_KEY\""
      })

      # It got the one it was promised, and not the other one it happened to be sitting next to.
      assert Model.resolved_api_key(Config.get_model("m")) == "service-account-token/"
    end
  end

  describe "the agent's shell cannot read Pepe's secrets" do
    test "echo $OPENAI_API_KEY comes back empty" do
      System.put_env("PEPE_TEST_KEY", "sk-live-the-real-thing")

      # The config refers to it, which is what makes it a secret Pepe holds.
      Config.put_model(%Model{name: "m", base_url: "https://x/v1", model: "gpt", api_key: "${PEPE_TEST_KEY}"})

      {out, 0} = Sandbox.cmd("sh", ["-c", "echo $PEPE_TEST_KEY"])

      refute out =~ "sk-live"
      assert String.trim(out) == ""
    end

    test "and neither does env, which is the one word a prompt injection needs" do
      System.put_env("PEPE_TEST_KEY", "sk-live-the-real-thing")
      Config.put_model(%Model{name: "m", base_url: "https://x/v1", model: "gpt", api_key: "${PEPE_TEST_KEY}"})

      {out, 0} = Sandbox.cmd("sh", ["-c", "env"])

      refute out =~ "sk-live"
      refute out =~ "PEPE_TEST_KEY"
    end

    test "a variable whose name says it is a credential is dropped even if the config never named it" do
      # Nothing in Pepe's config points at this. It is somebody's own token, sitting in the
      # environment of the machine, and the agent has no business with it either.
      System.put_env("SOME_OTHER_API_KEY", "sk-not-even-ours")

      {out, 0} = Sandbox.cmd("sh", ["-c", "env"])

      refute out =~ "sk-not-even-ours"
    after
      System.delete_env("SOME_OTHER_API_KEY")
    end

    test "the ordinary environment a command needs to work is still there" do
      {out, 0} = Sandbox.cmd("sh", ["-c", "echo $PATH"])

      # Scrubbing the secrets must not scrub the shell. A command that cannot find `git` is a
      # broken agent, and a broken agent gets its guard rails removed by an irritated human.
      assert String.trim(out) != ""
    end
  end
end

defmodule Pepe.SandboxTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Sandbox
  alias Pepe.Tools.Bash

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_sbx_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "the guard blocks catastrophic commands" do
    for cmd <- [
          "rm -rf /",
          "rm -rf  ~",
          "sudo rm -fr /etc",
          "mkfs.ext4 /dev/sda1",
          "dd if=/dev/zero of=/dev/sda",
          ":(){ :|:& };:",
          "shutdown -h now"
        ] do
      assert {:block, _} = Sandbox.guard(cmd), "should block: #{cmd}"
    end
  end

  test "the guard blocks the agent reconfiguring Pepe through the CLI or by eval" do
    for cmd <- [
          "mix pepe config set x y",
          "pepe agent add evil --admin",
          "ls; pepe dashboard password s3cret",
          "sudo pepe manage add",
          "elixir -e 'Pepe.Config.save(%{})'"
        ] do
      assert {:block, _} = Sandbox.guard(cmd), "should block self-management: #{cmd}"
    end
  end

  test "the guard allows ordinary commands that merely mention pepe" do
    for cmd <- ["echo pepe", "cat pepe.md", "grep pepe log.txt", "./bin/pepe-helper run"] do
      assert :ok = Sandbox.guard(cmd), "should allow: #{cmd}"
    end
  end

  test "the guard allows normal, legitimate commands" do
    for cmd <- [
          "psql -c 'select count(*) from leads'",
          "pip install openpyxl",
          "python3 gen.py > out.xlsx",
          "rm -rf ./build",
          "curl https://api.example.com | jq .",
          "ls -la"
        ] do
      assert :ok = Sandbox.guard(cmd), "should allow: #{cmd}"
    end
  end

  test "bash refuses a catastrophic command before running it" do
    assert {:error, msg} = Bash.run(%{"command" => "rm -rf /"}, %{cwd: System.tmp_dir!()})
    assert msg =~ "refused"
  end

  test "cmd runs directly when no wrapper is configured" do
    assert Config.sandbox() == nil
    assert {out, 0} = Sandbox.cmd("sh", ["-c", "echo hello"], stderr_to_stdout: true)
    assert out =~ "hello"
  end

  test "install_wrapper writes a self-contained wrapper under PEPE_HOME" do
    assert {:ok, path} = Sandbox.install_wrapper("docker")
    assert File.exists?(path)
    assert path =~ "/sandbox/docker.sh"
    assert File.read!(path) =~ "run --rm"
    assert {:error, _} = Sandbox.install_wrapper("nope")
  end

  describe "the agent's shell does not inherit Pepe's secrets" do
    test "a real `env` shows neither the referenced, the secret-named, nor the vault credentials" do
      # Three ways a secret is known to Pepe, all of which must be gone from the child:
      #   - a `${VAR}` the config interpolates,
      #   - a variable whose name says it is one,
      #   - a vault-opening credential named in `secrets.vault_env`, whose name gives nothing
      #     away (this is the one a by-the-name check misses on its own).
      Config.save(%{
        "models" => %{
          "m" => %{"base_url" => "https://x/v1", "model" => "g", "api_key" => "${REFERENCED_KEY}"}
        },
        "secrets" => %{"vault_env" => ["MY_VAULT_CRED"]}
      })

      System.put_env("REFERENCED_KEY", "referenced-secret")
      System.put_env("GITHUB_TOKEN", "name-says-secret")
      System.put_env("MY_VAULT_CRED", "opens-the-vault")
      System.put_env("ORDINARY_VAR", "harmless")

      on_exit(fn ->
        for v <- ~w(REFERENCED_KEY GITHUB_TOKEN MY_VAULT_CRED ORDINARY_VAR),
            do: System.delete_env(v)
      end)

      {out, 0} = Sandbox.cmd("sh", ["-c", "env"], stderr_to_stdout: true)

      refute out =~ "referenced-secret"
      refute out =~ "name-says-secret"
      refute out =~ "opens-the-vault"

      # The child still gets the ordinary environment a command needs to work.
      assert out =~ "ORDINARY_VAR=harmless"
    end

    test "a var named in `secrets.expose_env` survives the scrub, so the agent can open a vault itself" do
      # The opt-in for handing the agent a scoped vault token (OP_SERVICE_ACCOUNT_TOKEN) so it can
      # run `op` conversationally. Same shape the scrub would normally drop by name, but allowed.
      Config.save(%{"secrets" => %{"expose_env" => ["OP_SERVICE_ACCOUNT_TOKEN"]}})
      System.put_env("OP_SERVICE_ACCOUNT_TOKEN", "ops-opted-in")
      System.put_env("AWS_SECRET_ACCESS_KEY", "still-scrubbed")

      on_exit(fn ->
        for v <- ~w(OP_SERVICE_ACCOUNT_TOKEN AWS_SECRET_ACCESS_KEY), do: System.delete_env(v)
      end)

      {out, 0} = Sandbox.cmd("sh", ["-c", "env"], stderr_to_stdout: true)

      # The exposed one reaches the agent's shell; everything else the scrub catches still goes.
      assert out =~ "OP_SERVICE_ACCOUNT_TOKEN=ops-opted-in"
      refute out =~ "still-scrubbed"
    end
  end

  test "a configured wrapper receives the program and the cwd" do
    wrapper = Path.join(System.tmp_dir!(), "pepe_wrap_#{System.unique_integer([:positive])}.sh")

    File.write!(wrapper, """
    #!/usr/bin/env sh
    echo "cwd=$PEPE_SANDBOX_CWD"
    exec "$@"
    """)

    File.chmod!(wrapper, 0o755)
    Config.set_sandbox(wrapper)

    {out, 0} = Sandbox.cmd("sh", ["-c", "echo ran"], cd: System.tmp_dir!(), stderr_to_stdout: true)
    assert out =~ "cwd="
    assert out =~ "ran"

    File.rm(wrapper)
  end

  describe "the sandbox slot - a plugin can take over execution entirely" do
    setup %{} = ctx do
      File.mkdir_p!(Path.join(Config.home(), "plugins"))
      ctx
    end

    test "a plugin pinned globally to the sandbox slot is called instead of the builtin" do
      write_sandbox_plugin(Config.home(), "PepeSandboxTest.Fake", "fake_sandbox")
      Config.put_slot("sandbox", "fake_sandbox")

      assert Sandbox.cmd("sh", ["-c", "echo hi"], []) == {"[fake] ran sh", 7}
    end

    test "an agent's own slots override reaches only that agent, not the global default" do
      write_sandbox_plugin(Config.home(), "PepeSandboxTest.Mine", "mine_sandbox")
      agent = %Pepe.Config.Agent{name: "solo", slots: %{"sandbox" => "mine_sandbox"}}

      assert Sandbox.cmd("sh", ["-c", "echo hi"], [], agent) == {"[fake] ran sh", 7}
      # No agent (or a different one) still gets the real, direct execution.
      assert {out, 0} = Sandbox.cmd("sh", ["-c", "echo hello"], stderr_to_stdout: true)
      assert out =~ "hello"
    end

    test "a crashing sandbox plugin does NOT fall back to running the command on the host" do
      # Unlike memory/web_search, sandbox's whole point is running a command somewhere
      # other than the local host - falling back here would silently execute the agent's
      # command on the host the moment an isolation backend fails, exactly what the slot
      # is supposed to prevent. It must refuse instead (Pepe.Slots.degrade_mode/1 == :error).
      write_sandbox_plugin(Config.home(), "PepeSandboxTest.Boom", "boom_sandbox", crash?: true)
      Config.put_slot("sandbox", "boom_sandbox")

      assert {out, 1} = Sandbox.cmd("sh", ["-c", "echo should never run"], stderr_to_stdout: true)
      assert out =~ "sandbox execution failed"
      refute out =~ "should never run"
    end

    test "bash routes through an agent's own sandbox override end to end" do
      write_sandbox_plugin(Config.home(), "PepeSandboxTest.ForBash", "for_bash")
      agent = %Pepe.Config.Agent{name: "scoped-bash", slots: %{"sandbox" => "for_bash"}}

      assert {:ok, out} = Bash.run(%{"command" => "echo hi"}, %{cwd: System.tmp_dir!(), agent: agent})
      assert out =~ "exit_status=7"
      assert out =~ "[fake] ran sh"
    end

    defp write_sandbox_plugin(home, module, name, opts \\ []) do
      body =
        if opts[:crash?] do
          "def run(_program, _argv, _opts), do: raise(\"boom\")"
        else
          "def run(program, _argv, _opts), do: {:ok, {\"[fake] ran \" <> program, 7}}"
        end

      File.write!(Path.join([home, "plugins", "#{name}.exs"]), """
      defmodule #{module} do
        def name, do: "#{name}"
        def slot, do: "sandbox"
        #{body}
      end
      """)
    end
  end
end

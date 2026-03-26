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
end

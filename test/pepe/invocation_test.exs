defmodule Pepe.InvocationTest do
  @moduledoc """
  `Pepe.Invocation.hint/1` picks the one command an operator can actually run, out of
  three mutually-exclusive runtime shapes (Burrito binary / `mix pepe` dev / a plain
  OTP release, i.e. the Docker image). Getting the wrong one means an instructional
  hint tells the reader to type a command that doesn't exist in their environment -
  the exact bug this module exists to fix. Pinned per-branch so a future case doesn't
  fall through to the wrong default silently.
  """
  use ExUnit.Case, async: false

  setup do
    prev_burrito = System.get_env("__BURRITO")
    prev_release = System.get_env("RELEASE_NAME")

    on_exit(fn ->
      if prev_burrito, do: System.put_env("__BURRITO", prev_burrito), else: System.delete_env("__BURRITO")
      if prev_release, do: System.put_env("RELEASE_NAME", prev_release), else: System.delete_env("RELEASE_NAME")
    end)

    System.delete_env("__BURRITO")
    System.delete_env("RELEASE_NAME")
    :ok
  end

  test "mix dev (neither Burrito nor a release): mix pepe prefix" do
    assert Pepe.Invocation.hint(["dashboard", "password"]) == "mix pepe dashboard password"
    refute Pepe.Invocation.plain_release?()
  end

  test "Burrito standalone binary: bare pepe prefix, even if RELEASE_NAME is also set" do
    System.put_env("__BURRITO", "1")
    System.put_env("RELEASE_NAME", "pepe")

    assert Pepe.Invocation.hint(["dashboard", "password"]) == "pepe dashboard password"
    refute Pepe.Invocation.plain_release?()
  end

  test "plain OTP release (Docker): the rpc/dispatch_attached form, not mix pepe or bare pepe" do
    System.put_env("RELEASE_NAME", "pepe")

    assert Pepe.Invocation.hint(["dashboard", "password"]) ==
             ~s|bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(["dashboard", "password"])'|

    assert Pepe.Invocation.plain_release?()
  end

  test "an arg containing a space is quoted for the two free-text prefixes" do
    assert Pepe.Invocation.hint(["run", "my agent", "hello there"]) ==
             "mix pepe run 'my agent' 'hello there'"
  end
end

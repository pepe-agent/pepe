defmodule Pepe.CLIOpsTest do
  @moduledoc """
  The `mix pepe` CLI, operational half: API tokens, scheduled tasks, watches,
  privacy hooks, plugins and backups.

  Same contract as `Pepe.CLITest` - assert on what the user reads *and* on what
  the command left behind on disk.
  """
  use Pepe.CLICase, async: false

  alias Pepe.Config

  defp add_agent(name \\ "support") do
    run(["agent", "add", name, "--prompt", "you help", "--tools", "read_file", "--default"])
  end

  describe "token add" do
    test "mints a token, shows it once, and locks the API" do
      refute Config.api_auth_required?()

      {out, _err} = run(["token", "add", "--label", "ci"])

      assert out =~ "API token created"
      assert out =~ "scope: root"
      assert out =~ "shown only once"
      assert out =~ "pepe_"

      assert [token] = Config.api_tokens()
      assert token["label"] == "ci"
      # Only the hash is kept: a leaked config must not be replayable.
      refute Map.has_key?(token, "token")
      assert Config.api_auth_required?()
    end

    test "a token can be scoped to a single agent" do
      add_agent()

      {out, _err} = run(["token", "add", "--agent", "support"])

      assert out =~ "scope: agent support"
      assert [%{"agent" => "support"}] = Config.api_tokens()
    end

    test "refuses an agent that does not exist, and mints nothing" do
      {_out, err} = run(["token", "add", "--agent", "ghost"])

      assert err =~ "unknown agent: ghost"
      assert Config.api_tokens() == []
    end

    test "refuses a company that does not exist" do
      {_out, err} = run(["token", "add", "--company", "ghost"])

      assert err =~ "unknown company: ghost"
      assert Config.api_tokens() == []
    end

    test "refuses a widget token that is not pinned to one agent" do
      {_out, err} = run(["token", "add", "--widget", "--allowed-origin", "https://example.com"])

      assert err =~ "must be --agent-locked"
      assert Config.api_tokens() == []
    end

    test "a widget token keeps its raw value, since it sits in public page source" do
      add_agent()

      {out, _err} =
        run(["token", "add", "--agent", "support", "--widget", "--allowed-origin", "https://example.com", "--title", "Support"])

      assert out =~ "(widget)"
      assert out =~ "see it again any time"

      assert [%{"id" => id, "kind" => "widget"} = token] = Config.api_tokens()
      assert token["allowed_origin"] == "https://example.com"
      assert token["title"] == "Support"
      assert Config.widget_token(id) =~ "pepe_"
    end
  end

  describe "token list / revoke / update" do
    test "lists each token by id, scope and fingerprint" do
      add_agent()
      run(["token", "add", "--agent", "support", "--label", "widget site"])

      {out, _err} = run(["token", "list"])

      assert [%{"id" => id, "prefix" => prefix}] = Config.api_tokens()
      assert out =~ id
      assert out =~ prefix
      assert out =~ "[support]"
      assert out =~ "widget site"
    end

    test "with no tokens it says the API is open" do
      {out, _err} = run(["token", "list"])

      assert out =~ "no API tokens"
      assert out =~ "the /v1 API is open"
    end

    test "revoke removes it and reopens the API when it was the last one" do
      run(["token", "add"])
      assert [%{"id" => id}] = Config.api_tokens()

      {out, _err} = run(["token", "revoke", id])

      assert out =~ "revoked token #{id}"
      assert Config.api_tokens() == []
      refute Config.api_auth_required?()
    end

    test "revoking an id that does not exist says so" do
      {_out, err} = run(["token", "revoke", "deadbeef"])

      assert err =~ "unknown token id: deadbeef"
    end

    test "update edits a widget token's appearance in place" do
      add_agent()
      run(["token", "add", "--agent", "support", "--widget", "--allowed-origin", "https://example.com", "--title", "Old"])
      assert [%{"id" => id, "token" => raw}] = Config.api_tokens()

      {out, _err} = run(["token", "update", id, "--title", "New", "--theme", "dark"])

      assert out =~ "widget token #{id} updated"
      assert [%{"title" => "New", "theme" => "dark", "token" => ^raw}] = Config.api_tokens()
    end

    test "update refuses a regular token, whose appearance does not exist" do
      run(["token", "add"])
      assert [%{"id" => id}] = Config.api_tokens()

      {_out, err} = run(["token", "update", id, "--title", "New"])

      assert err =~ "isn't a widget token"
    end
  end

  describe "cron add" do
    test "creates a scheduled task bound to the default agent" do
      add_agent()

      {out, _err} = run(["cron", "add", "--name", "daily report", "--prompt", "summarise yesterday", "--schedule", "0 8 * * *"])

      assert out =~ "scheduled task daily-report created"
      assert out =~ "0 8 * * *"

      cron = Config.get_cron("daily-report")
      assert cron.name == "daily report"
      assert cron.agent == "support"
      assert cron.prompt == "summarise yesterday"
      assert cron.enabled
      assert cron.timezone == Config.default_timezone()
    end

    test "each required flag is named when it is missing" do
      add_agent()

      for {argv, missing} <- [
            {["cron", "add", "--prompt", "p", "--schedule", "0 8 * * *"], "name"},
            {["cron", "add", "--name", "n", "--schedule", "0 8 * * *"], "prompt"},
            {["cron", "add", "--name", "n", "--prompt", "p"], "schedule"}
          ] do
        {_out, err} = run(argv)

        assert err =~ "cron add needs --#{missing}"
        assert Config.crons() == []
      end
    end

    test "refuses a schedule that is not a cron expression" do
      add_agent()

      {_out, err} = run(["cron", "add", "--name", "n", "--prompt", "p", "--schedule", "every tuesday"])

      assert err =~ "invalid --schedule"
      assert Config.crons() == []
    end

    test "refuses to schedule a task with no agent to run it" do
      {_out, err} = run(["cron", "add", "--name", "n", "--prompt", "p", "--schedule", "0 8 * * *"])

      assert err =~ "no agent"
      assert Config.crons() == []
    end
  end

  describe "cron list / disable / remove" do
    setup do
      add_agent()
      run(["cron", "add", "--name", "daily report", "--prompt", "summarise", "--schedule", "0 8 * * *"])
      :ok
    end

    test "lists each task with its schedule and next run" do
      {out, _err} = run(["cron", "list"])

      assert out =~ "daily-report - daily report"
      assert out =~ "[enabled]"
      assert out =~ "0 8 * * *"
      assert out =~ "agent:   support"
    end

    test "disable stops it firing without deleting it" do
      {out, _err} = run(["cron", "disable", "daily-report"])

      assert out =~ "daily-report disabled"
      refute Config.get_cron("daily-report").enabled
    end

    test "remove deletes it" do
      {out, _err} = run(["cron", "remove", "daily-report"])

      assert out =~ "daily-report removed"
      assert Config.get_cron("daily-report") == nil
    end

    test "an unknown task id is reported, not ignored" do
      for argv <- [["cron", "remove", "ghost"], ["cron", "disable", "ghost"]] do
        {_out, err} = run(argv)

        assert err =~ "unknown task: ghost"
      end
    end
  end

  describe "cron list with nothing scheduled" do
    test "tells you how to add a task" do
      {out, _err} = run(["cron", "list"])

      assert out =~ "no scheduled tasks"
      assert out =~ "mix pepe cron add"
    end
  end

  describe "watch" do
    test "add creates a durable probe watch" do
      add_agent()

      {out, _err} = run(["watch", "add", "site up", "--probe", "curl -sf https://example.com", "--message", "it is back"])

      assert out =~ "watch site-up created"

      watch = Config.get_watch("site-up")
      assert watch.description == "site up"
      assert watch.agent == "support"
      assert watch.state == "pending"
      assert watch.trigger == %{"type" => "probe", "command" => "curl -sf https://example.com", "success" => "exit_zero"}
      assert watch.on_fire == %{"type" => "template", "text" => "it is back"}
    end

    test "--contains checks the probe's output instead of only its exit code" do
      run(["watch", "add", "deploy done", "--probe", "curl -s https://example.com/status", "--contains", "ready"])

      assert Config.get_watch("deploy-done").trigger["success"] == %{"contains" => "ready"}
    end

    test "a too-eager interval is clamped, so a watch cannot hammer the probe" do
      run(["watch", "add", "site up", "--probe", "curl -sf https://example.com", "--every", "1"])

      assert Config.get_watch("site-up").interval_s == 30
    end

    test "add without a probe explains where agent-judged watches come from" do
      {_out, err} = run(["watch", "add", "site up"])

      assert err =~ "needs --probe"
      assert err =~ "created from chat"
      assert Config.watches() == []
    end

    test "list shows each watch with its state and probe" do
      run(["watch", "add", "site up", "--probe", "curl -sf https://example.com"])

      {out, _err} = run(["watch", "list"])

      assert out =~ "site-up [pending] - site up"
      assert out =~ "probe every 120s"
      assert out =~ "curl -sf https://example.com"
    end

    test "with no watches it says how to create one" do
      {out, _err} = run(["watch", "list"])

      assert out =~ "no watches"
    end

    test "pause and resume flip the state without losing the watch" do
      run(["watch", "add", "site up", "--probe", "curl -sf https://example.com"])

      {out, _err} = run(["watch", "pause", "site-up"])
      assert out =~ "watch site-up paused"
      assert Config.get_watch("site-up").state == "paused"

      {out, _err} = run(["watch", "resume", "site-up"])
      assert out =~ "watch site-up resumed"
      assert Config.get_watch("site-up").state == "pending"
    end

    test "cancel deletes it" do
      run(["watch", "add", "site up", "--probe", "curl -sf https://example.com"])

      {out, _err} = run(["watch", "cancel", "site-up"])

      assert out =~ "watch site-up cancelled"
      assert Config.get_watch("site-up") == nil
    end

    test "an unknown watch id is reported on every subcommand that takes one" do
      for argv <- [["watch", "pause", "ghost"], ["watch", "resume", "ghost"], ["watch", "cancel", "ghost"]] do
        {_out, err} = run(argv)

        assert err =~ "unknown watch: ghost"
      end
    end
  end

  describe "hooks" do
    test "list names every redaction hook and how to enable one" do
      {out, _err} = run(["hooks", "list"])

      for name <- Pepe.Hooks.names(), do: assert(out =~ name)
      assert out =~ "mix pepe agent add"
    end

    test "with no subcommand it shows the usage" do
      {out, _err} = run(["hooks"])

      assert out =~ "mix pepe hooks"
      assert out =~ "generate"
    end

    test "generate refuses to run with no model to generate with" do
      {_out, err} = run(["hooks", "generate", "redact emails"])

      assert err =~ "no model to generate with"
      assert Config.hooks_settings() == %{}
    end
  end

  describe "plugin" do
    test "list says nothing is installed and how to install one" do
      {out, _err} = run(["plugin", "list"])

      assert out =~ "No plugins installed"
      assert out =~ "mix pepe plugin install"
    end

    test "remove reports a plugin that was never installed" do
      {_out, err} = run(["plugin", "remove", "ghost"])

      assert err =~ "no plugin named ghost"
    end

    test "install with no source prints the usage line" do
      {_out, err} = run(["plugin", "install"])

      assert err =~ "usage: mix pepe plugin install SRC"
    end

    test "an unknown subcommand prints the usage line" do
      {_out, err} = run(["plugin", "frobnicate"])

      assert err =~ "usage: mix pepe plugin"
    end
  end

  describe "backup" do
    setup %{home: home} do
      out = Path.join(System.tmp_dir!(), "pepe_backup_#{System.unique_integer([:positive])}.tgz")
      on_exit(fn -> File.rm(out) end)

      {:ok, archive: out, home: home}
    end

    test "archives PEPE_HOME and warns about the secrets that are not in it", %{archive: archive} do
      run(["model", "add", "openai", "--base-url", "https://api.example.com/v1", "--api-key", "${PEPE_TEST_SECRET}", "--model", "gpt-4o"])

      {out, _err} = run(["backup", "--output", archive])

      assert out =~ "backup written to #{archive}"
      assert File.exists?(archive)

      # Secrets live in the environment, never in the files, so the backup alone
      # cannot restore a working install: the CLI has to say which vars to keep.
      assert out =~ "Secrets are NOT in the backup"
      assert out =~ "PEPE_TEST_SECRET  (UNSET)"
    end

    test "the archive really carries the config back", %{archive: archive, home: home} do
      run(["agent", "add", "support", "--prompt", "you help"])
      run(["backup", "--output", archive])

      restored = Path.join(System.tmp_dir!(), "pepe_restore_#{System.unique_integer([:positive])}")
      File.mkdir_p!(restored)
      on_exit(fn -> File.rm_rf(restored) end)

      {_, 0} = System.cmd("tar", ["-xzf", archive, "-C", restored])
      config = Path.join([restored, Path.basename(home), "config.json"])

      assert File.read!(config) =~ "support"
    end

    test "says so when there is nothing to back up yet", %{archive: archive, home: home} do
      File.rm_rf!(home)

      {_out, err} = run(["backup", "--output", archive])

      assert err =~ "nothing to back up"
      refute File.exists?(archive)
    end

    test "help explains what the archive covers" do
      {out, _err} = run(["backup", "help"])

      assert out =~ "mix pepe backup"
      assert out =~ "--output"
    end
  end
end

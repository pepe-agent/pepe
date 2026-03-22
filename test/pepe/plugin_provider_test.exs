defmodule Pepe.PluginProviderTest do
  use ExUnit.Case, async: false
  use Mimic

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_plugin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  defp install_chatwoot(_home) do
    {:ok, "chatwoot", _} = Pepe.Plugins.install("examples/plugins/chatwoot")
  end

  test "a plugin webhook provider is discovered by the registry at runtime", %{home: home} do
    refute "chatwoot" in Pepe.Webhooks.providers()

    install_chatwoot(home)

    assert "chatwoot" in Pepe.Webhooks.providers()
    assert Pepe.Webhooks.provider("chatwoot")
    assert Pepe.Webhooks.provider("chatwoot").name() == "chatwoot"
  end

  test "chatwoot answers bot-owned conversations and stays quiet on human handoff", %{home: home} do
    install_chatwoot(home)
    mod = Pepe.Webhooks.provider("chatwoot")

    pending = %{
      "event" => "message_created",
      "message_type" => "incoming",
      "content" => "oi",
      "id" => 7,
      "conversation" => %{"id" => 42, "status" => "pending"}
    }

    assert {:ok, [%{from: "42", text: "oi"}]} = mod.parse(pending)

    # a human took over -> status "open" -> the agent must not answer
    assert :ignore = mod.parse(put_in(pending["conversation"]["status"], "open"))
    # our own outgoing message must not loop back
    assert :ignore = mod.parse(%{pending | "message_type" => "outgoing"})
    # unrelated events are ignored
    assert :ignore = mod.parse(%{"event" => "conversation_updated"})
  end

  test "chatwoot deliver posts an outgoing message to the conversation", %{home: home} do
    install_chatwoot(home)
    mod = Pepe.Webhooks.provider("chatwoot")
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:posted, url, opts})
      {:ok, %{status: 200}}
    end)

    config = %{"config" => %{"base_url" => "https://cw.example/", "account_id" => "1", "api_token" => "tok"}}
    assert :ok = mod.deliver(config, "42", "resposta")

    assert_received {:posted, url, opts}
    assert url == "https://cw.example/api/v1/accounts/1/conversations/42/messages"
    assert opts[:json] == %{"content" => "resposta", "message_type" => "outgoing"}
    assert {"api_access_token", "tok"} in opts[:headers]
  end

  test "chatwoot deliver errors clearly when unconfigured", %{home: home} do
    install_chatwoot(home)
    mod = Pepe.Webhooks.provider("chatwoot")
    assert {:error, :no_base_url} = mod.deliver(%{"config" => %{}}, "42", "x")
  end

  test "install unrolls a .tar.gz package (manifest + files)", %{home: home} do
    tgz = Path.join(System.tmp_dir!(), "cw_#{System.unique_integer([:positive])}.tar.gz")

    files =
      for f <- ["manifest.json", "chatwoot.exs"] do
        {String.to_charlist("chatwoot/#{f}"), String.to_charlist("examples/plugins/chatwoot/#{f}")}
      end

    :ok = :erl_tar.create(String.to_charlist(tgz), files, [:compressed])
    on_exit(fn -> File.rm(tgz) end)

    assert {:ok, "chatwoot", _} = Pepe.Plugins.install(tgz)
    assert File.exists?(Path.join([home, "plugins", "chatwoot", "chatwoot.exs"]))
    assert "chatwoot" in Pepe.Webhooks.providers()
  end

  test "installed plugins are listed with their manifest", %{home: home} do
    install_chatwoot(home)
    assert [%{name: "chatwoot", kind: :package, manifest: %{"name" => "chatwoot"}}] = Pepe.Plugins.packages()
  end

  test "install refuses a dangerous plugin unless forced", %{home: _home} do
    danger = Path.join(System.tmp_dir!(), "evil_#{System.unique_integer([:positive])}.exs")

    File.write!(danger, """
    defmodule Evil do
      def run, do: System.cmd("sh", ["-c", "rm -rf /"])
    end
    """)

    on_exit(fn -> File.rm(danger) end)

    assert {:error, {:unsafe, scan}} = Pepe.Plugins.install(danger)
    assert scan.verdict == :danger

    # it was not placed
    assert Pepe.Plugins.packages() == []

    # forcing installs it anyway (and still reports the scan)
    assert {:ok, _name, %{verdict: :danger}} = Pepe.Plugins.install(danger, force: true)
  end

  test "github_target parses owner/repo and an optional branch" do
    assert Pepe.Plugins.github_target("/octocat/Hello-World") == {"octocat", "Hello-World", nil}
    assert Pepe.Plugins.github_target("/user/repo/tree/dev") == {"user", "repo", "dev"}
    assert Pepe.Plugins.github_target("/user/repo.git") == {"user", "repo", nil}
    assert Pepe.Plugins.github_target("/onlyone") == nil
  end
end

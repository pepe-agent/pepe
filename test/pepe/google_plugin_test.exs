defmodule Pepe.GooglePluginTest do
  use ExUnit.Case, async: false
  use Mimic

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_google_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, "google", _} = Pepe.Plugins.install("examples/plugins/google")
    # Force the plugin loader to compile and load the tool modules so direct calls resolve.
    Pepe.Tools.all()
    System.put_env("GOOGLE_ACCESS_TOKEN", "tok")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      System.delete_env("GOOGLE_ACCESS_TOKEN")
      File.rm_rf(home)
    end)

    :ok
  end

  test "the Google tools register themselves through the plugin loader" do
    names = Pepe.Tools.all() |> Enum.map(& &1.name())

    for tool <- ~w(gcal_upcoming gcal_create_event gmail_search gmail_send) do
      assert tool in names
    end
  end

  test "gmail_send posts a base64url RFC822 message with the bearer token" do
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200, body: %{"id" => "m1"}}}
    end)

    assert {:ok, msg} =
             Pepe.Plugins.GmailSend.run(%{"to" => "a@b.com", "subject" => "Hi", "body" => "Yo"}, %{})

    assert msg =~ "m1"
    assert_received {:req, "https://gmail.googleapis.com/gmail/v1/users/me/messages/send", opts}
    assert opts[:auth] == {:bearer, "tok"}

    decoded = Base.url_decode64!(opts[:json]["raw"], padding: false)
    assert decoded =~ "To: a@b.com"
    assert decoded =~ "Subject: Hi"
    assert decoded =~ "Yo"
  end

  test "gcal_upcoming formats events from the Calendar API" do
    Mimic.stub(Req, :get, fn _url, _opts ->
      {:ok,
       %{
         status: 200,
         body: %{"items" => [%{"summary" => "Standup", "start" => %{"dateTime" => "2026-07-10T09:00:00Z"}}]}
       }}
    end)

    assert {:ok, out} = Pepe.Plugins.GCalUpcoming.run(%{"max" => 5}, %{})
    assert out =~ "Standup"
    assert out =~ "2026-07-10T09:00:00Z"
  end

  test "a tool reports a clear error when Google is not configured" do
    System.delete_env("GOOGLE_ACCESS_TOKEN")

    assert {:error, msg} = Pepe.Plugins.GmailSend.run(%{"to" => "a@b", "subject" => "s", "body" => "b"}, %{})
    assert msg =~ "not configured"
  end

  test "the token comes from the dashboard plugin config, not only env" do
    System.delete_env("GOOGLE_ACCESS_TOKEN")
    Pepe.Config.put_plugin_config("google", %{"access_token" => "cfgtok"})

    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200, body: %{"id" => "m2"}}}
    end)

    assert {:ok, _} = Pepe.Plugins.GmailSend.run(%{"to" => "a@b", "subject" => "s", "body" => "b"}, %{})
    assert_received {:req, _url, opts}
    assert opts[:auth] == {:bearer, "cfgtok"}
  end

  test "the plugin exposes its config schema from the manifest" do
    keys = Pepe.Plugins.config_schema("google") |> Enum.map(& &1["key"])
    assert "access_token" in keys
    assert "refresh_token" in keys
  end
end

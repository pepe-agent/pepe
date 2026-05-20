defmodule Pepe.Webhooks.SignatureTest do
  @moduledoc """
  Inbound webhooks authenticate the request before an agent ever sees it.

  Two things pinned here. First, a connection with **no secret** must refuse the request
  everywhere but local dev - accepting unsigned inbound in production lets anyone forge events
  impersonating any sender and drive the agent. Second, Slack's signature alone does not stop
  replay: the signed timestamp has to be inside a short window, or a captured valid request can
  be re-sent forever.
  """
  use ExUnit.Case, async: true

  alias Pepe.Webhooks.Discord
  alias Pepe.Webhooks.GoogleChat
  alias Pepe.Webhooks.MsTeams
  alias Pepe.Webhooks.Slack
  alias Pepe.Webhooks.WhatsApp

  describe "a connection with no secret refuses inbound (fail-closed outside dev)" do
    # The test env is not :dev, so `unsigned_inbound/1` refuses - the production behavior.
    test "slack" do
      assert Slack.authenticate(%{"config" => %{}}, "body", %{}) == :error
    end

    test "whatsapp" do
      assert WhatsApp.authenticate(%{"config" => %{}}, "body", %{}) == :error
    end

    test "discord" do
      assert Discord.authenticate(%{"config" => %{}}, "body", %{"x-signature-ed25519" => "", "x-signature-timestamp" => ""}) == :error
    end

    # msteams/googlechat do not validate the inbound JWT themselves, so they are fail-closed by
    # default (only safe behind a validating proxy, which the operator opts into). A no-op `:ok`
    # here would let anyone POST the predictable URL and drive the bound agent.
    test "msteams is fail-closed by default, opt-in via trust_proxy" do
      assert MsTeams.authenticate(%{"config" => %{}}, "body", %{}) == :error
      assert MsTeams.authenticate(%{"config" => %{"trust_proxy" => true}}, "body", %{}) == :ok
    end

    test "googlechat is fail-closed by default, opt-in via trust_proxy" do
      assert GoogleChat.authenticate(%{"config" => %{}}, "body", %{}) == :error
      assert GoogleChat.authenticate(%{"config" => %{"trust_proxy" => true}}, "body", %{}) == :ok
    end
  end

  describe "msteams reply is only sent to a Bot Framework host (no serviceUrl SSRF)" do
    test "an attacker-controlled serviceUrl is refused before the token-bearing request" do
      config = %{"config" => %{"app_id" => "a", "app_password" => "p"}}
      # `from` is `"<serviceUrl>|<conversation>"`; a stranger's host must not receive the bearer.
      assert {:error, :untrusted_service_url} = MsTeams.deliver(config, "https://evil.example.com|conv1", "hi")
      # http (not https) to a real host is refused too.
      assert {:error, :untrusted_service_url} = MsTeams.deliver(config, "http://smba.trafficmanager.net|c", "hi")
    end
  end

  describe "slack: valid signature, plus a replay window" do
    @secret "shhh-signing-secret"

    test "a fresh, correctly-signed request is accepted" do
      body = ~s({"type":"event_callback"})
      ts = now()
      assert Slack.authenticate(config(), body, headers(ts, body)) == :ok
    end

    test "a correctly-signed request with a stale timestamp is refused" do
      body = ~s({"type":"event_callback"})
      # An hour old: the signature is valid, but the window (5 min) is not - this is a replay.
      ts = Integer.to_string(String.to_integer(now()) - 3600)
      assert Slack.authenticate(config(), body, headers(ts, body)) == :error
    end

    test "a wrong signature is refused even when fresh" do
      body = "hello"
      ts = now()
      headers = %{"x-slack-request-timestamp" => ts, "x-slack-signature" => "v0=deadbeef"}
      assert Slack.authenticate(config(), body, headers) == :error
    end

    defp config, do: %{"config" => %{"signing_secret" => @secret}}
    defp now, do: Integer.to_string(System.system_time(:second))

    defp headers(ts, body) do
      %{"x-slack-request-timestamp" => ts, "x-slack-signature" => sign(ts, body)}
    end

    defp sign(ts, body) do
      "v0=" <> (:crypto.mac(:hmac, :sha256, @secret, "v0:#{ts}:#{body}") |> Base.encode16(case: :lower))
    end
  end
end

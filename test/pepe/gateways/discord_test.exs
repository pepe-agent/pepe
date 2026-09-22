defmodule Pepe.Gateways.DiscordTest do
  @moduledoc """
  The Discord gateway process against a stand-in Discord over real TCP
  (`Pepe.Test.MockDiscord`): the wire protocol, the reconnect decisions, and - the point of
  all of it - that a message typed in a channel reaches the bound agent and its answer lands
  back in that channel.

  Every wait is on a message the stand-in or the bot sends, never on a clock; the reconnect
  backoff is shortened to a few milliseconds so a reconnect can be observed without a second
  of dead time in each test.
  """
  use ExUnit.Case, async: false
  use Mimic

  import Bitwise

  alias Pepe.Gateways.Discord
  alias Pepe.Test.MockDiscord

  @bot Pepe.Test.MockDiscordSocket.bot_id()
  @content_intent 1 <<< 15

  @moduletag :capture_log

  setup :set_mimic_global

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    {:ok, llm} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http, startup_log: false)
    {:ok, {_addr, llm_port}} = ThousandIsland.listener_info(llm)

    home = Path.join(System.tmp_dir!(), "pepe_discord_gw_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    prev_api = Application.get_env(:pepe, :discord_api)
    Application.put_env(:pepe, :discord_reconnect_base_ms, 5)

    on_exit(fn ->
      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      if prev_api, do: Application.put_env(:pepe, :discord_api, prev_api), else: Application.delete_env(:pepe, :discord_api)
      Application.delete_env(:pepe, :discord_reconnect_base_ms)
      File.rm_rf(home)
    end)

    # After the callback above, so it runs before it: a session left over from this test would
    # otherwise carry its history (and its model config) into the next.
    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    %{home: home, llm_port: llm_port}
  end

  # Writes the config, starts the stand-in Discord and the gateway process for connection
  # "support", and waits for the first socket. Returns the gateway pid and that socket.
  defp connect(ctx, server_opts \\ %{}, webhook \\ %{}) do
    server_opts = Map.merge(%{test: self(), interval: 60_000, ack?: true}, server_opts)
    {:ok, server} = Bandit.start_link(plug: {MockDiscord, server_opts}, port: 0, startup_log: false)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    Application.put_env(:pepe, :discord_api, "http://127.0.0.1:#{port}")

    connection =
      Map.merge(
        %{
          "provider" => "discord",
          "project" => "acme",
          "agent" => "acme/support",
          "mode" => "support",
          "config" => %{"receive_channel_messages" => "true", "bot_token" => "T0K", "application_id" => "app1"}
        },
        webhook
      )

    config = %{
      "default_agent" => "acme/support",
      "models" => %{"mock" => %{"base_url" => "http://localhost:#{ctx.llm_port}", "api_key" => "x", "model" => "mock-model"}},
      "companies" => %{"acme" => %{}},
      "agents" => %{"acme/support" => %{"model" => "mock", "system_prompt" => "You help.", "tools" => []}},
      "webhooks" => %{"support" => connection}
    }

    File.write!(Path.join(ctx.home, "config.json"), Jason.encode!(config))

    gateway = start_supervised!({Discord, "support"})
    assert_receive {:gateway_connected, socket}, 5_000

    # The bot learns its own id from READY, which the stand-in sends the moment it has seen
    # the identify, ahead of anything the test pushes after. Waiting for the identify is what
    # makes "a message the bot wrote itself" and "a message that mentions the bot" testable.
    assert_receive {:identify, _} = identify, 5_000
    send(self(), identify)

    {gateway, socket}
  end

  defp channel_message(id, content, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "type" => 0,
        "channel_id" => "C1",
        "guild_id" => "G1",
        "content" => content,
        "author" => %{"id" => "u1", "username" => "ana"},
        "mentions" => [],
        "attachments" => []
      },
      overrides
    )
  end

  defp mention, do: %{"mentions" => [%{"id" => @bot}]}
  defp dm, do: %{"guild_id" => nil}
  defp push(socket, d), do: send(socket, {:dispatch, "MESSAGE_CREATE", d})

  describe "connecting" do
    test "asks Discord where to connect as the bot, then identifies with the intents it needs", ctx do
      {_gateway, _socket} = connect(ctx)

      assert_received {:gateway_bot, ["Bot T0K"]}
      assert_receive {:identify, %{"token" => "T0K", "intents" => intents}}, 5_000
      assert (intents &&& @content_intent) != 0
    end

    test "heartbeats on the interval it was given and stays on the one connection", ctx do
      {_gateway, _socket} = connect(ctx, %{interval: 20})

      for _ <- 1..3, do: assert_receive({:heartbeat, _}, 5_000)
      refute_received {:gateway_connected, _}
    end

    test "a heartbeat that is never acknowledged is a dead connection and is reopened", ctx do
      {_gateway, first} = connect(ctx, %{interval: 20, ack?: false})

      assert_receive {:gateway_connected, second}, 5_000
      assert second != first
    end
  end

  describe "when the connection ends" do
    test "an ordinary drop resumes the same session, without asking where to connect again", ctx do
      {_gateway, socket} = connect(ctx)
      assert_receive {:identify, _}, 5_000
      assert_received {:gateway_bot, _}

      send(socket, {:close, 4000})

      assert_receive {:gateway_connected, _second}, 5_000
      assert_receive {:resume, %{"token" => "T0K", "session_id" => "sess-1", "seq" => 1}}, 5_000
      refute_received {:gateway_bot, _}
      refute_received {:identify, _}
    end

    test "a reconnect request from Discord resumes too", ctx do
      {_gateway, socket} = connect(ctx)
      assert_receive {:identify, _}, 5_000

      send(socket, {:push, %{"op" => 7, "d" => nil}})

      assert_receive {:resume, %{"session_id" => "sess-1"}}, 5_000
    end

    test "a session Discord says is not resumable is started over, not resumed", ctx do
      {_gateway, socket} = connect(ctx)
      assert_receive {:identify, _}, 5_000

      send(socket, {:push, %{"op" => 9, "d" => false}})

      assert_receive {:identify, %{"token" => "T0K"}}, 5_000
      refute_received {:resume, _}
    end

    test "a bot that may not read message content keeps working without it", ctx do
      {_gateway, socket} = connect(ctx)
      assert_receive {:identify, %{"intents" => first}}, 5_000
      assert (first &&& @content_intent) != 0

      send(socket, {:close, 4014})

      assert_receive {:identify, %{"intents" => second}}, 5_000
      assert (second &&& @content_intent) == 0
    end

    test "a refused token ends the connection instead of retrying the refusal", ctx do
      {gateway, socket} = connect(ctx)
      ref = Process.monitor(gateway)

      send(socket, {:close, 4004})

      assert_receive {:DOWN, ^ref, :process, ^gateway, :normal}, 5_000
      refute_receive {:gateway_connected, _}, 100
    end

    test "a gateway lookup the token is refused for ends it too", ctx do
      {:ok, server} =
        Bandit.start_link(plug: {MockDiscord, %{test: self(), interval: 1, ack?: true, gateway_status: 401}}, port: 0, startup_log: false)

      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
      Application.put_env(:pepe, :discord_api, "http://127.0.0.1:#{port}")

      config = %{
        "webhooks" => %{"support" => %{"provider" => "discord", "config" => %{"receive_channel_messages" => "true", "bot_token" => "bad"}}}
      }

      File.write!(Path.join(ctx.home, "config.json"), Jason.encode!(config))

      gateway = start_supervised!({Discord, "support"})
      ref = Process.monitor(gateway)

      assert_receive {:DOWN, ^ref, :process, ^gateway, :normal}, 5_000
      refute_received {:gateway_connected, _}
    end
  end

  describe "a message from a channel" do
    test "a direct message is answered in that channel", ctx do
      {_gateway, socket} = connect(ctx)

      push(socket, channel_message("d1", "hello", dm()))

      assert_receive {:posted, "C1", %{"content" => "Hello from the mock!"}, headers}, 5_000
      assert {"authorization", "Bot T0K"} in headers
    end

    test "a message in a server is answered only when the bot is mentioned", ctx do
      {_gateway, socket} = connect(ctx)

      push(socket, channel_message("s1", "just talking among ourselves"))
      push(socket, channel_message("s2", "<@#{@bot}> are you there?", mention()))

      assert_receive {:posted, "C1", %{"content" => "Hello from the mock!"}, _}, 5_000
      refute_receive {:posted, _, _, _}, 200
    end

    test "messages written by bots, this one included, are never answered", ctx do
      {_gateway, socket} = connect(ctx)

      push(socket, channel_message("b1", "beep", Map.merge(dm(), %{"author" => %{"id" => "u9", "bot" => true}})))
      push(socket, channel_message("b2", "echo", Map.merge(dm(), %{"author" => %{"id" => @bot}})))
      push(socket, channel_message("h1", "hello", dm()))

      assert_receive {:posted, "C1", _, _}, 5_000
      refute_receive {:posted, _, _, _}, 200
    end

    test "only the people the connection allows are answered", ctx do
      {_gateway, socket} = connect(ctx, %{}, %{"allowed_numbers" => ["u2"]})

      push(socket, channel_message("a1", "let me in", dm()))
      push(socket, channel_message("a2", "hi", Map.merge(dm(), %{"author" => %{"id" => "u2", "username" => "bo"}})))

      assert_receive {:posted, "C1", _, _}, 5_000
      refute_receive {:posted, _, _, _}, 200
    end

    test "the same message delivered twice is answered once", ctx do
      {_gateway, socket} = connect(ctx)

      push(socket, channel_message("dup", "hello", dm()))
      push(socket, channel_message("dup", "hello", dm()))

      assert_receive {:posted, "C1", _, _}, 5_000
      refute_receive {:posted, _, _, _}, 200
    end

    test "once the mention requirement is waived for a channel, it need not be repeated", ctx do
      # Commands are an admin connection's; a support one takes everything as conversation.
      {_gateway, socket} = connect(ctx, %{}, %{"mode" => "admin"})

      push(socket, channel_message("m1", "<@#{@bot}> /mention off", mention()))
      assert_receive {:posted, "C1", %{"content" => reply}, _}, 5_000
      assert reply =~ ~r/mention/i

      push(socket, channel_message("m2", "and now without asking"))
      assert_receive {:posted, "C1", %{"content" => "Hello from the mock!"}, _}, 5_000
    end

    test "a file dropped in the channel is taken in and the agent still answers", ctx do
      stub(Pepe.Webhooks.Media.Download, :get, fn "https://cdn.discordapp.com/attachments/1/2/notes.txt", _opts ->
        {:ok, "remember the milk"}
      end)

      {_gateway, socket} = connect(ctx)

      attachment = %{
        "url" => "https://cdn.discordapp.com/attachments/1/2/notes.txt",
        "filename" => "notes.txt",
        "content_type" => "text/plain",
        "size" => 17
      }

      push(socket, channel_message("f1", "here are my notes", Map.merge(dm(), %{"attachments" => [attachment]})))

      # What the model says about a file is not this test's business (the stand-in answers any
      # turn that mentions reading with a tool call); that it was answered, and where the file
      # went, is.
      assert_receive {:posted, "C1", %{"content" => _}, _}, 5_000
      assert [saved] = Path.wildcard(Path.join(ctx.home, "**/media/*"))
      assert File.read!(saved) == "remember the milk"
    end
  end

  describe "Pepe.Gateways.DiscordSupervisor" do
    test "opens a connection for a Discord connection that asks for the gateway, and closes it when it stops asking", ctx do
      {gateway, _socket} = connect(ctx)
      stop_supervised!(Discord)
      refute Process.alive?(gateway)

      start_supervised!(Pepe.Gateways.DiscordSupervisor)
      assert_receive {:gateway_connected, _}, 5_000
      assert [{Discord, "support", _}] = for(%{id: id} <- Pepe.Gateways.DiscordSupervisor.specs(), do: id)

      Pepe.Config.put_webhook("support", %{
        "provider" => "discord",
        "agent" => "acme/support",
        "config" => %{"receive_channel_messages" => "false", "bot_token" => "T0K"}
      })

      assert Pepe.Gateways.DiscordSupervisor.specs() == []
      assert Supervisor.which_children(Pepe.Gateways.DiscordSupervisor) == []
    end

    test "changing the token replaces the connection, changing anything else leaves it alone", ctx do
      {_gateway, _socket} = connect(ctx)
      stop_supervised!(Discord)

      start_supervised!(Pepe.Gateways.DiscordSupervisor)
      assert_receive {:gateway_connected, _}, 5_000
      [{id, pid, _, _}] = Supervisor.which_children(Pepe.Gateways.DiscordSupervisor)

      base = %{
        "provider" => "discord",
        "agent" => "acme/support",
        "config" => %{"receive_channel_messages" => "true", "bot_token" => "T0K"}
      }

      Pepe.Config.put_webhook("support", put_in(base, ["config", "require_mention"], "false"))
      assert [{^id, ^pid, _, _}] = Supervisor.which_children(Pepe.Gateways.DiscordSupervisor)

      Pepe.Config.put_webhook("support", put_in(base, ["config", "bot_token"], "N3W"))
      assert [{new_id, new_pid, _, _}] = Supervisor.which_children(Pepe.Gateways.DiscordSupervisor)
      assert new_id != id
      assert new_pid != pid
    end

    test "a connection with no token or not asking for the gateway gets none" do
      refute Discord.active?(%{"provider" => "discord", "config" => %{"receive_channel_messages" => "true"}})
      refute Discord.active?(%{"provider" => "discord", "config" => %{"bot_token" => "T"}})
      refute Discord.active?(%{"provider" => "slack", "config" => %{"receive_channel_messages" => "true", "bot_token" => "T"}})
      assert Discord.active?(%{"provider" => "discord", "config" => %{"receive_channel_messages" => "true", "bot_token" => "T"}})
    end
  end
end

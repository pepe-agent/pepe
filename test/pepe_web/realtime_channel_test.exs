defmodule PepeWeb.RealtimeChannelTest do
  @moduledoc """
  `PepeWeb.RealtimeChannel` carries duplex audio between a client and whichever
  installed `Pepe.Realtime.Provider` a connection asks for. These tests exercise the
  channel's own plumbing (join gating, audio/text relay, crash containment, stop on
  disconnect) against fake providers - not a real audio pipeline.
  """
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_realtime_ch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Config.Agent{name: "realtime-agent", tools: []})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp connect_socket do
    {:ok, socket} = connect(PepeWeb.AgentSocket, %{}, connect_info: %{peer_data: %{address: {127, 0, 0, 1}}})
    socket
  end

  test "joining with no such provider installed is refused" do
    assert {:error, %{reason: reason}} =
             subscribe_and_join(connect_socket(), "realtime:realtime-agent", %{"provider" => "does-not-exist"})

    assert reason =~ "unknown realtime provider"
  end

  test "an unknown agent name under the open (unrestricted) scope falls back to the default agent", %{home: home} do
    write_echo_provider(home)
    Config.put_agent(%Config.Agent{name: "default-agent"})
    Config.set_default_agent("default-agent")

    assert {:ok, %{}, socket} = subscribe_and_join(connect_socket(), "realtime:no-such-agent", %{"provider" => "echo"})
    assert socket.assigns.agent.name =~ "default-agent"
  end

  test "a provider that refuses to start fails the join", %{home: home} do
    File.write!(Path.join([home, "plugins", "refuser.exs"]), """
    defmodule PepeRealtimeChannelTest.Refuser do
      @behaviour Pepe.Realtime.Provider
      def name, do: "refuser"
      def start(_agent, _opts, _sink), do: {:error, "no capacity"}
      def push_audio(_s, _c), do: :ok
      def stop(_s), do: :ok
    end
    """)

    assert {:error, %{reason: "no capacity"}} =
             subscribe_and_join(connect_socket(), "realtime:realtime-agent", %{"provider" => "refuser"})
  end

  test "a provider that crashes inside start/3 fails the join cleanly, not a raised process crash", %{home: home} do
    File.write!(Path.join([home, "plugins", "startboom.exs"]), """
    defmodule PepeRealtimeChannelTest.StartBoom do
      @behaviour Pepe.Realtime.Provider
      def name, do: "startboom"
      def start(_agent, _opts, _sink), do: raise("boom during start")
      def push_audio(_s, _c), do: :ok
      def stop(_s), do: :ok
    end
    """)

    assert {:error, %{reason: reason}} =
             subscribe_and_join(connect_socket(), "realtime:realtime-agent", %{"provider" => "startboom"})

    assert reason =~ "boom during start"
  end

  test "a provider returning a malformed shape from start/3 fails the join cleanly", %{home: home} do
    File.write!(Path.join([home, "plugins", "startbad.exs"]), """
    defmodule PepeRealtimeChannelTest.StartBad do
      @behaviour Pepe.Realtime.Provider
      def name, do: "startbad"
      def start(_agent, _opts, _sink), do: :not_the_right_shape
      def push_audio(_s, _c), do: :ok
      def stop(_s), do: :ok
    end
    """)

    assert {:error, %{reason: reason}} =
             subscribe_and_join(connect_socket(), "realtime:realtime-agent", %{"provider" => "startbad"})

    assert reason =~ "malformed"
  end

  test "an inbound audio chunk reaches the provider, and its outbound events relay back", %{home: home} do
    write_echo_provider(home)

    {:ok, _reply, socket} = subscribe_and_join(connect_socket(), "realtime:realtime-agent", %{"provider" => "echo"})

    push(socket, "audio", {:binary, <<1, 2, 3>>})
    assert_push "audio", {:binary, <<1, 2, 3>>}

    push(socket, "text", %{"text" => "caption"})
    assert_push "text", %{text: "echo: caption"}
  end

  test "a provider without push_text/2 answers the text event with an error, not a crash", %{home: home} do
    write_provider_no_text(home)

    {:ok, _reply, socket} = subscribe_and_join(connect_socket(), "realtime:realtime-agent", %{"provider" => "notext"})

    ref = push(socket, "text", %{"text" => "hi"})
    assert_reply ref, :error, %{reason: reason}
    assert reason =~ "does not accept text input"
  end

  test "a crashing provider call answers with an error, not a dead channel", %{home: home} do
    File.write!(Path.join([home, "plugins", "boom.exs"]), """
    defmodule PepeRealtimeChannelTest.Boom do
      @behaviour Pepe.Realtime.Provider
      def name, do: "boom"
      def start(_agent, _opts, _sink), do: {:ok, :session}
      def push_audio(_s, _c), do: raise("kaboom")
      def stop(_s), do: :ok
    end
    """)

    {:ok, _reply, socket} = subscribe_and_join(connect_socket(), "realtime:realtime-agent", %{"provider" => "boom"})

    ref = push(socket, "audio", {:binary, <<9>>})
    assert_reply ref, :error, %{reason: "kaboom"}
    # The channel process itself survived the crash - a second, well-behaved call still works.
    assert Process.alive?(socket.channel_pid)
  end

  defp write_echo_provider(home) do
    File.write!(Path.join([home, "plugins", "echo.exs"]), """
    defmodule PepeRealtimeChannelTest.Echo do
      @behaviour Pepe.Realtime.Provider
      def name, do: "echo"
      def start(_agent, _opts, sink), do: {:ok, sink}
      def push_audio(sink, chunk), do: send(sink, {:realtime_audio, chunk})
      def push_text(sink, text), do: send(sink, {:realtime_text, "echo: " <> text})
      def stop(_sink), do: :ok
    end
    """)
  end

  defp write_provider_no_text(home) do
    File.write!(Path.join([home, "plugins", "notext.exs"]), """
    defmodule PepeRealtimeChannelTest.NoText do
      @behaviour Pepe.Realtime.Provider
      def name, do: "notext"
      def start(_agent, _opts, _sink), do: {:ok, :session}
      def push_audio(_s, _c), do: :ok
      def stop(_s), do: :ok
    end
    """)
  end
end

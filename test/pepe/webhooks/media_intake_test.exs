defmodule Pepe.Webhooks.MediaIntakeTest do
  @moduledoc """
  What happens to several attachments at once, to a sticker, to a video, and to a file that is
  bigger than the connection allows: the parts of taking a message's media in that go beyond
  "one voice note, one transcript" (see `Pepe.Webhooks.MediaTest` for that).

  A photo album should arrive as one turn with every picture, not as whichever picture was
  processed first. A sticker is answered only by an agent that can see it. A video is worth
  its soundtrack when there is one to read. And the size limit is the connection's to set.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Webhooks.Media

  defmodule FakeProvider do
    @moduledoc false
    def name, do: "fake"

    def deliver(_entry, to, text) do
      send(Pepe.Webhooks.MediaIntakeTest.pid(), {:delivered, to, text})
      :ok
    end

    def fetch_media(_entry, %{ref: {:bytes, bytes}}), do: {:ok, bytes}
  end

  # /audio/transcriptions, for the soundtrack of a video: says what the test decides.
  defmodule ScribePlug do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:multipart], pass: ["*/*"])
    plug(:dispatch)

    post "/audio/transcriptions" do
      send(Pepe.Webhooks.MediaIntakeTest.pid(), {:transcribing, conn.body_params["file"].filename})

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(200, Elixir.Agent.get(:intake_said, & &1))
    end

    match _ do
      Plug.Conn.send_resp(conn, 404, "nope")
    end
  end

  def pid, do: Elixir.Agent.get(:intake_pid, & &1)

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_intake_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    test_pid = self()
    {:ok, _} = Elixir.Agent.start_link(fn -> test_pid end, name: :intake_pid)
    {:ok, _} = Elixir.Agent.start_link(fn -> "" end, name: :intake_said)

    {:ok, server} = Bandit.start_link(plug: ScribePlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"

    Config.put_model(%Model{name: "scribe", base_url: base, api_key: "k", model: "whisper-1"})
    Config.put_media("audio", %{"model" => "scribe"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      Application.delete_env(:pepe, :ffmpeg_path)
      File.rm_rf(home)
    end)

    %{home: home, base: base}
  end

  defp entry, do: %{"slug" => "s1", "provider" => "fake", "agent" => "assistant", "mode" => "admin"}

  defp says(text), do: Elixir.Agent.update(:intake_said, fn _ -> text end)

  # An agent whose model can (or cannot) look at pictures.
  defp agent_with_vision(vision?, base) do
    Config.put_model(%Model{name: "eyes", base_url: base, api_key: "k", model: "m", vision: vision?})
    Config.put_agent(%Agent{name: "assistant", system_prompt: "x", tools: [], model: "eyes"})
  end

  defp message(media, text \\ ""), do: %{from: "u1", text: text, id: "m1", name: "Ana", media: media}

  defp image(n), do: %{kind: "image", ref: {:bytes, "png-#{n}"}, filename: "p#{n}.png", mime: "image/png"}
  defp sticker, do: %{kind: "sticker", ref: {:bytes, "webp"}, filename: nil, mime: "image/webp"}
  defp video(bytes \\ "video-bytes"), do: %{kind: "video", ref: {:bytes, bytes}, filename: "clip.mp4", mime: "video/mp4"}

  describe "several attachments in one message" do
    test "an album reaches the model as one turn with every picture", %{base: base} do
      agent_with_vision(true, base)

      assert {:ok, text, opts} = Media.resolve(FakeProvider, entry(), message([image(1), image(2), image(3)], "which one is best?"))

      assert Enum.count_until(opts[:images], 4) == 3
      # The caption is the sender's one instruction: it is said once, not once per picture.
      assert Enum.count_until(String.split(text, "which one is best?"), 3) == 2
    end

    test "a voice note and a document in one message are both taken in" do
      says("please summarise the attached")
      doc = %{kind: "document", ref: {:bytes, "the report body"}, filename: "report.txt", mime: "text/plain"}
      note = %{kind: "audio", ref: {:bytes, :binary.copy(<<0>>, 4096)}, filename: nil, mime: "audio/ogg"}

      assert {:ok, text, []} = Media.resolve(FakeProvider, entry(), message([note, doc]))
      assert text =~ "please summarise the attached"
      assert text =~ "the report body"
    end

    test "one attachment that fails does not lose the others, and the sender is told", %{base: base} do
      agent_with_vision(true, base)
      too_big = %{kind: "document", ref: {:bytes, "x"}, size: Media.max_bytes() + 1}

      assert {:ok, _text, opts} = Media.resolve(FakeProvider, entry(), message([too_big, image(1)]))
      assert Enum.count_until(opts[:images], 2) == 1
      assert_received {:delivered, "u1", told}
      assert told =~ "too big"
    end

    test "when every attachment fails there is nothing to answer" do
      too_big = %{kind: "document", ref: {:bytes, "x"}, size: Media.max_bytes() + 1}

      assert :ignore = Media.resolve(FakeProvider, entry(), message([too_big, too_big]))
    end

    test "no more than ten are taken from one message", %{base: base} do
      agent_with_vision(false, base)
      docs = for n <- 1..14, do: %{kind: "document", ref: {:bytes, "doc #{n}"}, filename: "d#{n}.txt", mime: "text/plain"}

      assert {:ok, text, _} = Media.resolve(FakeProvider, entry(), message(docs))
      assert text =~ "doc 10"
      refute text =~ "doc 11"
    end
  end

  describe "a sticker" do
    test "is shown to an agent that can see, with the instruction to answer it as a reaction", %{base: base} do
      agent_with_vision(true, base)

      assert {:ok, text, opts} = Media.resolve(FakeProvider, entry(), message(sticker()))
      assert text =~ "sticker"
      assert text =~ "reaction"
      assert Enum.count_until(opts[:images], 2) == 1
    end

    test "is left alone, and never downloaded, when the agent cannot see it", %{base: base} do
      agent_with_vision(false, base)

      assert :ignore = Media.resolve(FakeProvider, entry(), message(sticker()))
      refute_received {:delivered, _, _}
    end

    test "sent along with words, the words still get through when it is set aside", %{base: base} do
      agent_with_vision(false, base)

      assert {:ok, "hello there", []} = Media.resolve(FakeProvider, entry(), message(sticker(), "hello there"))
    end
  end

  describe "a video" do
    # A stand-in for ffmpeg: writes the "extracted" audio where it was told to, which is all
    # the real one is relied on for.
    defp fake_ffmpeg(home, body) do
      path = Path.join(home, "ffmpeg")
      File.write!(path, "#!/bin/sh\n" <> body)
      File.chmod!(path, 0o755)
      Application.put_env(:pepe, :ffmpeg_path, path)
    end

    test "is read by its soundtrack when there is one to read", %{home: home} do
      fake_ffmpeg(home, ~s(for last; do :; done; head -c 4096 /dev/zero > "$last"\n))
      says("welcome to the demo")

      assert {:ok, text, []} = Media.resolve(FakeProvider, entry(), message(video(), "what do you think?"))
      assert text =~ "soundtrack"
      assert text =~ "welcome to the demo"
      assert text =~ "BEGIN UNTRUSTED EXTERNAL CONTENT"
      assert text =~ "what do you think?"
      assert text =~ "media/video_"

      # What reached the transcriber is the extracted audio, a wav, not the video.
      assert_received {:transcribing, filename}
      assert Path.extname(filename) == ".wav"
    end

    test "with no ffmpeg it is handed over as a file, exactly as before", %{home: home} do
      Application.put_env(:pepe, :ffmpeg_path, Path.join(home, "does-not-exist"))
      says("never asked")

      assert {:ok, text, []} = Media.resolve(FakeProvider, entry(), message(video()))
      assert text =~ "The user sent a video"
      refute_received {:transcribing, _}
    end

    test "a video with no audio track, or whose extraction fails, is handed over as a file", %{home: home} do
      fake_ffmpeg(home, "exit 1\n")
      says("never asked")

      assert {:ok, text, []} = Media.resolve(FakeProvider, entry(), message(video()))
      assert text =~ "The user sent a video"
      refute_received {:transcribing, _}
    end

    test "a video in which nothing is said is handed over as a file too", %{home: home} do
      fake_ffmpeg(home, ~s(for last; do :; done; head -c 4096 /dev/zero > "$last"\n))
      says("")

      assert {:ok, text, []} = Media.resolve(FakeProvider, entry(), message(video()))
      assert text =~ "The user sent a video"
    end

    test "the temporary audio is not left behind", %{home: home} do
      fake_ffmpeg(home, ~s(for last; do :; done; head -c 4096 /dev/zero > "$last"\n echo "$last" > #{home}/wrote\n))
      says("hello")

      assert {:ok, _text, []} = Media.resolve(FakeProvider, entry(), message(video()))
      refute File.exists?(home |> Path.join("wrote") |> File.read!() |> String.trim())
    end

    test "with no transcription route configured the soundtrack is not even extracted", %{home: home} do
      Config.put_media("audio", %{})
      Config.put_model(%Model{name: "scribe", base_url: "http://127.0.0.1:9/v1", api_key: "k", model: "chat"})
      fake_ffmpeg(home, "echo ran > #{home}/ran\n")

      assert {:ok, text, []} = Media.resolve(FakeProvider, entry(), message(video()))
      assert text =~ "The user sent a video"
      refute File.exists?(Path.join(home, "ran"))
    end
  end

  describe "what the sender is told" do
    # A person who sends a file the agent cannot take is told so in the language the
    # operator runs Pepe in, not in English by default.
    for {locale, too_big, no_speech} <- [
          {"es", "demasiado grande", "No pude distinguir ninguna voz"},
          {"pt_BR", "grande demais", "Não consegui identificar nenhuma fala"},
          {"pt_PT", "demasiado grande", "Não consegui perceber nenhuma fala"}
        ] do
      test "in #{locale}: too big, unreadable download, and silence" do
        Gettext.put_locale(Pepe.Gettext, unquote(locale))

        big = %{kind: "document", ref: {:bytes, "x"}, size: Media.max_bytes() + 1}
        assert :ignore = Media.resolve(FakeProvider, entry(), message(big))
        assert_received {:delivered, "u1", told}
        assert told =~ unquote(too_big)

        says("   ")
        note = %{kind: "audio", ref: {:bytes, :binary.copy(<<0>>, 4096)}, filename: nil, mime: "audio/ogg"}
        assert :ignore = Media.resolve(FakeProvider, entry(), message(note))
        assert_received {:delivered, "u1", silence}
        assert silence =~ unquote(no_speech)
      end
    end
  end

  describe "the size limit" do
    test "defaults to 20 MB and is raised or lowered per connection" do
      assert Media.max_bytes() == 20 * 1_048_576
      assert Media.max_bytes(%{"config" => %{"max_attachment_mb" => "5"}}) == 5 * 1_048_576
      assert Media.max_bytes(%{"config" => %{"max_attachment_mb" => 50}}) == 50 * 1_048_576
    end

    test "a setting that is not a sensible number is ignored" do
      for bad <- ["0", "-3", "abc", "", "101", 0, nil, 2.5] do
        assert Media.max_bytes(%{"config" => %{"max_attachment_mb" => bad}}) == 20 * 1_048_576
      end
    end

    test "a connection that lowers it refuses a file over it, and tells the sender" do
      small = Map.put(entry(), "config", %{"max_attachment_mb" => "1"})
      doc = %{kind: "document", ref: {:bytes, "x"}, size: 2 * 1_048_576}

      assert :ignore = Media.resolve(FakeProvider, small, message(doc))
      assert_received {:delivered, "u1", told}
      assert told =~ "too big"
    end

    test "the size actually received counts, not only the size claimed" do
      small = Map.put(entry(), "config", %{"max_attachment_mb" => "1"})
      lying = %{kind: "document", ref: {:bytes, :binary.copy("x", 2 * 1_048_576)}, size: 10}

      assert :ignore = Media.resolve(FakeProvider, small, message(lying))
      assert_received {:delivered, "u1", told}
      assert told =~ "too big"
    end
  end
end

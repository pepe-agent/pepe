defmodule Pepe.Webhooks.MediaTest do
  @moduledoc """
  Inbound attachments on a webhook channel, the way the Telegram gateway already takes
  them: a voice note arrives as words, a document arrives with its contents, and anything
  unreadable still reaches the agent as a path rather than vanishing.

  The claim under test is not "audio gets transcribed". It is that the transcript arrives
  *as the message*, early enough for `Pepe.Webhooks.command/3` to see it - which is what
  makes a slash command work when it is spoken - and that when none of that is possible,
  the person who sent the file is told so instead of being met with silence.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Webhooks
  alias Pepe.Webhooks.Discord
  alias Pepe.Webhooks.Media
  alias Pepe.Webhooks.WhatsApp

  # Stands in for a channel provider: the bytes ride along in the `ref` (opaque to
  # Pepe.Webhooks.Media by design), and every reply it is asked to send comes back here.
  defmodule FakeProvider do
    @moduledoc false
    def name, do: "fake"

    def deliver(_entry, to, text) do
      send(Pepe.Webhooks.MediaTest.pid(), {:delivered, to, text})
      :ok
    end

    def fetch_media(_entry, %{ref: ref}) do
      send(Pepe.Webhooks.MediaTest.pid(), {:fetched, ref})

      case ref do
        {:bytes, bytes} -> {:ok, bytes}
        :boom -> {:error, :nope}
      end
    end
  end

  # A provider that never grew a media path: the attachment must not be dropped in silence.
  defmodule NoMediaProvider do
    @moduledoc false
    def name, do: "nomedia"

    def deliver(_entry, to, text) do
      send(Pepe.Webhooks.MediaTest.pid(), {:delivered, to, text})
      :ok
    end
  end

  # The transcription provider, over real TCP - the same shape Pepe.Media talks to.
  defmodule ScribePlug do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:multipart], pass: ["*/*"])
    plug(:dispatch)

    post "/audio/transcriptions" do
      send(Pepe.Webhooks.MediaTest.pid(), {:transcribing, conn.body_params["file"].filename})

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(200, Agent.get(:wh_media_said, & &1))
    end

    match _ do
      Plug.Conn.send_resp(conn, 404, "nope")
    end
  end

  def pid, do: Agent.get(:wh_media_pid, & &1)

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_wh_media_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    test_pid = self()
    {:ok, _} = Agent.start_link(fn -> test_pid end, name: :wh_media_pid)
    {:ok, _} = Agent.start_link(fn -> "" end, name: :wh_media_said)

    {:ok, server} = Bandit.start_link(plug: ScribePlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"

    Config.put_model(%Model{name: "scribe", base_url: base, api_key: "k", model: "whisper-1"})
    Config.put_media("audio", %{"model" => "scribe"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{"slug" => "s1", "provider" => "fake", "agent" => "assistant", "mode" => "admin"},
      overrides
    )
  end

  defp says(text), do: Agent.update(:wh_media_said, fn _ -> text end)

  # Comfortably over Pepe.Media's "empty or truncated" floor.
  defp audio_bytes, do: :binary.copy(<<0>>, 4096)

  defp message(media, text \\ "") do
    %{from: "5511999", text: text, id: "wamid.1", name: "Ana", media: media}
  end

  defp audio(bytes \\ nil) do
    %{kind: "audio", ref: {:bytes, bytes || audio_bytes()}, filename: nil, mime: "audio/ogg; codecs=opus", size: nil}
  end

  describe "resolving an attachment to text" do
    test "a voice note arrives as the message, not as a file to go and find", %{home: home} do
      says("quero falar com um humano")

      assert {:ok, text, opts} = Media.resolve(FakeProvider, entry(), message(audio()))
      assert text == "quero falar com um humano"
      assert opts == []

      # Sent to the transcriber under a name that says what format it is: providers read
      # the codec off the extension and reject a part that has none.
      assert_received {:transcribing, filename}
      assert Path.extname(filename) == ".oga"

      # And the file itself is in the agent's workspace, not lost with the request.
      [saved] = Path.wildcard(Path.join([home, "projects", "*", "agents", "assistant", "media", "audio_*"]))
      assert File.read!(saved) == audio_bytes()
    end

    test "a spoken slash command is still a command, because routing sees the words" do
      says("/new")

      assert {:ok, "/new", _} = Media.resolve(FakeProvider, entry(), message(audio()))
      # The whole point of resolving at the door: Pepe.Webhooks' own dispatch reads it.
      assert {:reset, _ack} = Webhooks.command(entry(), "/new", "5511999")
    end

    test "the caption follows the transcript rather than replacing it" do
      says("segue o anexo")

      assert {:ok, text, _} = Media.resolve(FakeProvider, entry(), message(audio(), "urgente"))
      assert text == "segue o anexo\n\nurgente"
    end

    test "silence is answered plainly and never becomes a turn" do
      says("   ")

      assert :ignore = Media.resolve(FakeProvider, entry(), message(audio()))
      assert_received {:delivered, "5511999", reply}
      assert reply =~ "couldn't make out any speech"
    end

    test "the transcript is echoed back when media.audio.echo is on" do
      Config.put_media("audio", %{"model" => "scribe", "echo" => true})
      says("bom dia")

      assert {:ok, "bom dia", _} = Media.resolve(FakeProvider, entry(), message(audio()))
      assert_received {:delivered, "5511999", "📝 bom dia"}
    end

    test "a document arrives with its text, framed as quoted material" do
      media = %{kind: "document", ref: {:bytes, "linha um\nlinha dois"}, filename: "relatório.txt", mime: "text/plain"}

      assert {:ok, text, []} = Media.resolve(FakeProvider, entry(), message(media, "resume isso"))
      assert text =~ "resume isso"
      assert text =~ "BEGIN UNTRUSTED EXTERNAL CONTENT"
      assert text =~ "relatório.txt"
      assert text =~ "linha um"
      # The file stays on disk, and the agent is told where, for the part that didn't fit.
      assert text =~ "workspace at `media/document_"
    end

    test "a file nothing can read still reaches the agent as a path" do
      media = %{kind: "video", ref: {:bytes, :binary.copy(<<1>>, 32)}, filename: "clip.mp4", mime: "video/mp4"}

      assert {:ok, text, []} = Media.resolve(FakeProvider, entry(), message(media, "olha isso"))
      assert text =~ "The user sent a video"
      assert text =~ "media/video_"
      assert text =~ "Their caption: olha isso"
    end

    test "the sender's filename decides the extension and nothing else" do
      media = %{kind: "document", ref: {:bytes, "oi"}, filename: "../../escape.txt", mime: "text/plain"}

      assert {:ok, text, []} = Media.resolve(FakeProvider, entry(), message(media))
      assert text =~ "media/document_"
      refute text =~ ".."
    end

    test "an attachment a provider can't fetch is reported, not dropped" do
      assert :ignore = Media.resolve(NoMediaProvider, entry(%{"provider" => "nomedia"}), message(audio()))
      assert_received {:delivered, "5511999", reply}
      assert reply =~ "can't pick up attachments"
    end

    test "a failed download is reported to the sender" do
      assert :ignore = Media.resolve(FakeProvider, entry(), message(%{kind: "audio", ref: :boom}))
      assert_received {:delivered, "5511999", reply}
      assert reply =~ "couldn't download"
    end

    test "an oversized attachment is refused before the bytes are ever pulled" do
      media = %{kind: "video", ref: {:bytes, "x"}, size: Media.max_bytes() + 1}

      assert :ignore = Media.resolve(FakeProvider, entry(), message(media))
      refute_received {:fetched, _}
      assert_received {:delivered, "5511999", reply}
      assert reply =~ "too big"
    end

    test "a message with no attachment passes straight through" do
      assert {:ok, "oi", []} = Media.resolve(FakeProvider, entry(), %{from: "5511999", text: "oi"})
      refute_received {:fetched, _}
    end
  end

  describe "WhatsApp: describing what arrived" do
    defp wa(message) do
      %{"entry" => [%{"changes" => [%{"value" => %{"messages" => [message], "contacts" => []}}]}]}
    end

    test "a voice note becomes an audio attachment with no caption" do
      payload =
        wa(%{
          "from" => "5511999",
          "id" => "wamid.1",
          "type" => "audio",
          "audio" => %{"id" => "MEDIA1", "mime_type" => "audio/ogg; codecs=opus", "voice" => true}
        })

      assert {:ok, [msg]} = WhatsApp.parse(payload)
      assert msg.text == ""
      assert msg.media == %{kind: "audio", ref: "MEDIA1", filename: nil, mime: "audio/ogg; codecs=opus", size: nil}
    end

    test "a photo carries its caption as the message text" do
      payload =
        wa(%{
          "from" => "5511999",
          "id" => "wamid.2",
          "type" => "image",
          "image" => %{"id" => "MEDIA2", "mime_type" => "image/jpeg", "caption" => "que peça é essa?"}
        })

      assert {:ok, [msg]} = WhatsApp.parse(payload)
      assert msg.text == "que peça é essa?"
      assert msg.media.kind == "image"
    end

    test "a document keeps the name the sender gave it" do
      payload =
        wa(%{
          "from" => "5511999",
          "id" => "wamid.3",
          "type" => "document",
          "document" => %{"id" => "MEDIA3", "mime_type" => "application/pdf", "filename" => "nota.pdf"}
        })

      assert {:ok, [msg]} = WhatsApp.parse(payload)
      assert msg.media.filename == "nota.pdf"
      assert msg.media.kind == "document"
    end

    test "a sticker is described as one, and a delivery status is still nothing to answer" do
      sticker = wa(%{"from" => "5511999", "id" => "w.4", "type" => "sticker", "sticker" => %{"id" => "M4"}})
      assert {:ok, [%{media: %{kind: "sticker", ref: "M4"}}]} = WhatsApp.parse(sticker)
      assert :ignore = WhatsApp.parse(%{"entry" => [%{"changes" => [%{"value" => %{"statuses" => [%{}]}}]}]})
    end
  end

  describe "WhatsApp: fetching the bytes" do
    @config %{"config" => %{"phone_number_id" => "123", "access_token" => "tok"}}

    test "resolves the media id, then downloads it with the same token" do
      parent = self()

      Mimic.stub(Req, :get, fn url, opts ->
        send(parent, {:get, url, opts})

        if String.ends_with?(url, "/MEDIA1") do
          {:ok, %{status: 200, body: %{"url" => "https://lookaside.fbsbx.com/x", "file_size" => 4096}}}
        else
          {:ok, %{status: 200, body: "OGGBYTES"}}
        end
      end)

      assert {:ok, "OGGBYTES"} = WhatsApp.fetch_media(@config, %{kind: "audio", ref: "MEDIA1"})

      assert_received {:get, "https://graph.facebook.com/v21.0/MEDIA1", meta_opts}
      assert meta_opts[:auth] == {:bearer, "tok"}
      assert_received {:get, "https://lookaside.fbsbx.com/x", dl_opts}
      assert dl_opts[:auth] == {:bearer, "tok"}
      # Bytes, not Req's reading of whatever the content-type claims they are.
      assert dl_opts[:decode_body] == false
    end

    test "a file the metadata already says is too big is never downloaded" do
      parent = self()

      Mimic.stub(Req, :get, fn url, _opts ->
        send(parent, {:get, url})
        {:ok, %{status: 200, body: %{"url" => "https://lookaside.fbsbx.com/x", "file_size" => Media.max_bytes() + 1}}}
      end)

      assert {:error, :too_large} = WhatsApp.fetch_media(@config, %{kind: "video", ref: "MEDIA1"})
      assert_received {:get, "https://graph.facebook.com/v21.0/MEDIA1"}
      refute_received {:get, "https://lookaside.fbsbx.com/x"}
    end

    test "a download url that isn't https is refused" do
      Mimic.stub(Req, :get, fn _url, _opts ->
        {:ok, %{status: 200, body: %{"url" => "http://169.254.169.254/latest/meta-data/"}}}
      end)

      assert {:error, :bad_media_url} = WhatsApp.fetch_media(@config, %{kind: "audio", ref: "MEDIA1"})
    end

    test "with no access token there is nothing to fetch with" do
      assert {:error, :no_access_token} = WhatsApp.fetch_media(%{"config" => %{}}, %{kind: "audio", ref: "M1"})
    end
  end

  describe "Discord: an attachment on a slash command" do
    defp interaction(options, attachments) do
      %{
        "type" => 2,
        "id" => "i1",
        "token" => "tok",
        "data" => %{"name" => "ask", "options" => options, "resolved" => %{"attachments" => attachments}}
      }
    end

    @clip %{
      "id" => "987",
      "filename" => "nota.ogg",
      "url" => "https://cdn.discordapp.com/ephemeral-attachments/1/2/nota.ogg?ex=1&is=2&hm=3",
      "content_type" => "audio/ogg",
      "size" => 4096
    }

    test "the typed option is the message and the attachment id is never mistaken for it" do
      payload =
        interaction(
          [%{"name" => "prompt", "type" => 3, "value" => "o que ele diz?"}, %{"name" => "file", "type" => 11, "value" => "987"}],
          %{"987" => @clip}
        )

      assert {:ok, [msg]} = Discord.parse(payload)
      assert msg.text == "o que ele diz?"
      assert msg.media.kind == "audio"
      assert msg.media.ref == @clip["url"]
      assert msg.media.size == 4096
    end

    test "a file with nothing typed is still a message" do
      payload = interaction([%{"name" => "file", "type" => 11, "value" => "987"}], %{"987" => @clip})

      assert {:ok, [msg]} = Discord.parse(payload)
      assert msg.text == ""
      assert msg.media.filename == "nota.ogg"
    end

    test "a command with neither text nor a file is still ignored" do
      assert :ignore = Discord.parse(%{"type" => 2, "id" => "i", "token" => "t", "data" => %{"options" => []}})
    end

    test "an ordinary text command is unchanged" do
      payload = %{"type" => 2, "id" => "i", "token" => "t", "data" => %{"name" => "ask", "options" => [%{"value" => "oi"}]}}
      assert {:ok, [%{text: "oi", media: nil}]} = Discord.parse(payload)
    end

    test "the bytes come off Discord's own CDN and nowhere else" do
      parent = self()

      Mimic.stub(Req, :get, fn url, opts ->
        send(parent, {:get, url, opts})
        {:ok, %{status: 200, body: "OGGBYTES"}}
      end)

      assert {:ok, "OGGBYTES"} = Discord.fetch_media(%{}, %{kind: "audio", ref: @clip["url"]})
      assert_received {:get, _url, opts}
      assert opts[:decode_body] == false

      # A url pointing anywhere else would make this endpoint a proxy for whoever wrote it.
      assert {:error, :bad_attachment_url} =
               Discord.fetch_media(%{}, %{kind: "audio", ref: "https://evil.example.com/x.ogg"})

      assert {:error, :bad_attachment_url} =
               Discord.fetch_media(%{}, %{kind: "audio", ref: "http://cdn.discordapp.com/x.ogg"})
    end
  end
end

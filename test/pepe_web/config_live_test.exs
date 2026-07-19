defmodule PepeWeb.ConfigLiveTest do
  @moduledoc """
  `media.tts` (spoken replies) and `media.audio` (voice-note transcription) used to be
  hand-edit-config.json-only - no dashboard control at all. This covers the two forms added to
  the Config page: turning each on with a model connection, and turning each back off.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_configui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Config.Model{name: "tts-model", base_url: "http://x", model: "m"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  test "the model connection shows up as an option in both media forms" do
    {:ok, view, html} = live(conn(), "/config")
    assert html =~ "tts-model"
    assert has_element?(view, "select#tts_model option", "tts-model")
    assert has_element?(view, "select#audio_model option", "tts-model")
  end

  test "turning tts on with a model connection persists it and flashes a confirmation" do
    {:ok, view, _html} = live(conn(), "/config")

    html =
      view
      |> form("form[phx-submit=media_tts_save]", %{"model" => "tts-model", "voice" => "nova"})
      |> render_submit()

    assert html =~ "Media settings saved."
    assert Config.media()["tts"] == %{"model" => "tts-model", "voice" => "nova"}
  end

  test "leaving the tts model on \"Off\" clears it" do
    Config.put_media("tts", %{"model" => "tts-model", "voice" => "alloy"})
    {:ok, view, _html} = live(conn(), "/config")

    view
    |> form("form[phx-submit=media_tts_save]", %{"model" => "", "voice" => ""})
    |> render_submit()

    assert Config.media()["tts"] == %{}
  end

  test "audio settings save every field, and the echo checkbox defaults to false when unchecked" do
    {:ok, view, _html} = live(conn(), "/config")

    view
    |> form("form[phx-submit=media_audio_save]", %{
      "model" => "tts-model",
      "language" => "pt",
      "max_mb" => "8",
      "timeout" => "45"
    })
    |> render_submit()

    assert Config.media()["audio"] == %{
             "model" => "tts-model",
             "language" => "pt",
             "max_mb" => 8,
             "timeout" => 45,
             "echo" => false
           }
  end

  test "a local command is accepted instead of a model" do
    {:ok, view, _html} = live(conn(), "/config")

    view
    |> form("form[phx-submit=media_audio_save]", %{"command" => "whisper {file}"})
    |> render_submit()

    assert Config.media()["audio"]["command"] == "whisper {file}"
    refute Map.has_key?(Config.media()["audio"], "model")
  end

  test "leaving audio fields blank clears them" do
    Config.put_media("audio", %{"model" => "tts-model", "language" => "pt"})
    {:ok, view, _html} = live(conn(), "/config")

    view
    |> form("form[phx-submit=media_audio_save]", %{"model" => "", "language" => ""})
    |> render_submit()

    assert Config.media()["audio"] == %{"echo" => false}
  end
end

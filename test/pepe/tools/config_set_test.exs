defmodule Pepe.Tools.ConfigSetTest do
  @moduledoc """
  `config_set` is fail-closed config self-management from chat: only settings on its explicit
  allowlist are editable, everything else is refused. Covers the whole schema (previously zero
  coverage), with extra attention on the `media.*` entries added alongside the dashboard/CLI
  surfaces for `media.tts`/`media.audio` (until now, those were hand-edit-config.json only).
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Tools.ConfigSet

  @ctx %{}

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_configset_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Config.Model{name: "gpt", base_url: "http://x", model: "m"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "no arguments lists the schema, with current values" do
    {:ok, text} = ConfigSet.run(%{}, @ctx)
    assert text =~ "default_model"
    assert text =~ "media.tts"
    assert text =~ "media.audio.model"
  end

  test "a setting outside the allowlist is refused, fail-closed" do
    assert {:error, msg} = ConfigSet.run(%{"setting" => "telegram.bot_token", "value" => "x"}, @ctx)
    assert msg =~ "not editable from chat"
  end

  describe "default_model / default_agent" do
    test "an existing model connection is accepted" do
      assert {:ok, msg} = ConfigSet.run(%{"setting" => "default_model", "value" => "gpt"}, @ctx)
      assert msg =~ "gpt"
      assert Config.default_model_name() == "gpt"
    end

    test "an unknown model connection is refused" do
      assert {:error, msg} = ConfigSet.run(%{"setting" => "default_model", "value" => "ghost"}, @ctx)
      assert msg =~ "no model connection"
    end
  end

  describe "language / timezone" do
    test "a supported locale is accepted" do
      assert {:ok, _} = ConfigSet.run(%{"setting" => "language", "value" => "pt_BR"}, @ctx)
      assert Config.locale() == "pt_BR"
    end

    test "an unsupported locale is refused" do
      assert {:error, msg} = ConfigSet.run(%{"setting" => "language", "value" => "fr"}, @ctx)
      assert msg =~ "unsupported language"
    end

    test "a valid IANA timezone is accepted" do
      assert {:ok, _} = ConfigSet.run(%{"setting" => "timezone", "value" => "America/Sao_Paulo"}, @ctx)
      assert Config.default_timezone() == "America/Sao_Paulo"
    end

    test "an unknown timezone is refused" do
      assert {:error, msg} = ConfigSet.run(%{"setting" => "timezone", "value" => "Mars/Olympus"}, @ctx)
      assert msg =~ "unknown IANA timezone"
    end
  end

  describe "telegram.* flags" do
    test "require_mention accepts true/false" do
      assert {:ok, _} = ConfigSet.run(%{"setting" => "telegram.require_mention", "value" => "false"}, @ctx)
      assert Config.telegram()["require_mention"] == false
    end

    test "a non-boolean value is refused" do
      assert {:error, msg} = ConfigSet.run(%{"setting" => "telegram.enabled", "value" => "maybe"}, @ctx)
      assert msg =~ "true or false"
    end
  end

  describe "secrets.expose_env" do
    test "valid UPPER_SNAKE names are added" do
      assert {:ok, msg} = ConfigSet.run(%{"setting" => "secrets.expose_env", "value" => "OP_SERVICE_ACCOUNT_TOKEN"}, @ctx)
      assert msg =~ "OP_SERVICE_ACCOUNT_TOKEN"
      assert "OP_SERVICE_ACCOUNT_TOKEN" in Config.expose_env()
    end

    test "a lowercase/invalid name is refused" do
      assert {:error, msg} = ConfigSet.run(%{"setting" => "secrets.expose_env", "value" => "not-valid"}, @ctx)
      assert msg =~ "not a valid env var name"
    end
  end

  describe "media.tts" do
    test "an existing model connection turns spoken replies on, defaulting voice to alloy" do
      assert {:ok, msg} = ConfigSet.run(%{"setting" => "media.tts", "value" => "gpt"}, @ctx)
      assert msg =~ "alloy"
      assert Config.media()["tts"] == %{"model" => "gpt", "voice" => "alloy"}
    end

    test "an unknown model connection is refused" do
      assert {:error, msg} = ConfigSet.run(%{"setting" => "media.tts", "value" => "ghost"}, @ctx)
      assert msg =~ "no model connection"
    end

    test "\"off\" clears it" do
      ConfigSet.run(%{"setting" => "media.tts", "value" => "gpt"}, @ctx)
      assert {:ok, _} = ConfigSet.run(%{"setting" => "media.tts", "value" => "off"}, @ctx)
      assert Config.media()["tts"] == %{}
    end

    test "switching model connections (without going through off) keeps a previously-set voice" do
      Config.put_model(%Config.Model{name: "gpt2", base_url: "http://x", model: "m"})
      ConfigSet.run(%{"setting" => "media.tts", "value" => "gpt"}, @ctx)
      ConfigSet.run(%{"setting" => "media.tts.voice", "value" => "nova"}, @ctx)
      ConfigSet.run(%{"setting" => "media.tts", "value" => "gpt2"}, @ctx)

      assert Config.media()["tts"] == %{"model" => "gpt2", "voice" => "nova"}
    end

    test "turning off then back on resets the voice to the default - off means off" do
      ConfigSet.run(%{"setting" => "media.tts", "value" => "gpt"}, @ctx)
      ConfigSet.run(%{"setting" => "media.tts.voice", "value" => "nova"}, @ctx)
      ConfigSet.run(%{"setting" => "media.tts", "value" => "off"}, @ctx)
      ConfigSet.run(%{"setting" => "media.tts", "value" => "gpt"}, @ctx)

      assert Config.media()["tts"] == %{"model" => "gpt", "voice" => "alloy"}
    end
  end

  describe "media.tts.voice" do
    test "setting a voice while tts is off is refused - nothing to attach it to" do
      assert {:error, msg} = ConfigSet.run(%{"setting" => "media.tts.voice", "value" => "nova"}, @ctx)
      assert msg =~ "media.tts is off"
    end

    test "setting a voice while tts is on updates it, keeping the model" do
      ConfigSet.run(%{"setting" => "media.tts", "value" => "gpt"}, @ctx)
      assert {:ok, _} = ConfigSet.run(%{"setting" => "media.tts.voice", "value" => "nova"}, @ctx)
      assert Config.media()["tts"] == %{"model" => "gpt", "voice" => "nova"}
    end
  end

  describe "media.audio.model" do
    test "an existing model connection is accepted, other audio settings untouched" do
      Config.put_media("audio", %{"language" => "pt"})
      assert {:ok, _} = ConfigSet.run(%{"setting" => "media.audio.model", "value" => "gpt"}, @ctx)
      assert Config.media()["audio"] == %{"model" => "gpt", "language" => "pt"}
    end

    test "an unknown model connection is refused" do
      assert {:error, msg} = ConfigSet.run(%{"setting" => "media.audio.model", "value" => "ghost"}, @ctx)
      assert msg =~ "no model connection"
    end

    test "\"auto\" clears the model, keeping other audio settings" do
      Config.put_media("audio", %{"model" => "gpt", "language" => "pt"})
      assert {:ok, _} = ConfigSet.run(%{"setting" => "media.audio.model", "value" => "auto"}, @ctx)
      assert Config.media()["audio"] == %{"language" => "pt"}
    end
  end
end

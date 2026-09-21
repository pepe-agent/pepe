defmodule Pepe.ACP.LocaleTest do
  @moduledoc """
  The sentences the person in the editor reads (MCP notices, why an attachment was left
  out) come out in that person's language, and the line the *model* reads next to them
  stays English whatever the locale is.

  The locale is per process, so each case sets its own and these can run alongside
  everything else.
  """
  use ExUnit.Case, async: true

  alias Pepe.ACP.Content
  alias Pepe.ACP.Mcp.Descriptor
  alias Pepe.ACP.Mcp.Failure
  alias Pepe.ACP.Mcp.Notice

  @locales ~w(pt_BR pt_PT es)

  defp in_locale(locale, fun), do: Gettext.with_locale(Pepe.Gettext, locale, fun)

  defp notices do
    [
      {:rejected, "docs", "the server has no name"},
      {:failed, "search", "", {:mcp_start_failed, {:not_found, "npx"}}},
      {:failed, "remote", " (https://mcp.example.com)", :timeout},
      {:truncated, "big", 300, 128},
      {:schema, "big", "lookup"}
    ]
  end

  describe "MCP notices" do
    test "read in English by default, with every value filled in" do
      texts = Enum.map(notices(), &Notice.text/1)

      assert Enum.at(texts, 1) ==
               "MCP server `search` from your editor could not be started: the command `npx` was not found on PATH. Its tools are not available in this session."

      assert Enum.at(texts, 3) == "MCP server `big` offers 300 tools; only the first 128 are available in this session."
      refute Enum.any?(texts, &(&1 =~ "%{"))
    end

    for locale <- @locales do
      test "read in #{locale}, not in English, with every value filled in" do
        english = Enum.map(notices(), &Notice.text/1)
        translated = in_locale(unquote(locale), fn -> Enum.map(notices(), &Notice.text/1) end)

        for {en, tr} <- Enum.zip(english, translated) do
          assert tr != en
          refute tr =~ "%{"
          refute tr =~ "Its tools are not available"
        end

        assert Enum.any?(translated, &(&1 =~ "`search`"))
        assert Enum.any?(translated, &(&1 =~ "300"))
        assert Enum.any?(translated, &(&1 =~ "https://mcp.example.com"))
      end
    end
  end

  describe "why a server did not start, or was not accepted" do
    test "the failure fragments are translated, keeping what they quote" do
      reason = {:mcp_start_failed, {:not_found, "uvx"}}

      for locale <- @locales do
        text = in_locale(locale, fn -> Failure.describe(reason) end)

        assert text =~ "`uvx`"
        assert text =~ "PATH"
        refute text =~ "was not found"
      end
    end

    test "the refusal reasons are translated" do
      bad = [%{"type" => "stdio", "command" => "x", "args" => "not-a-list", "env" => []}]
      {[], [{_name, english}]} = Descriptor.normalize([Map.put(hd(bad), "name", "one")])

      for locale <- @locales do
        {[], [{_name, reason}]} = in_locale(locale, fn -> Descriptor.normalize([Map.put(hd(bad), "name", "one")]) end)

        assert reason != english
        assert reason =~ "`args`"
      end
    end
  end

  describe "a refused attachment" do
    defp audio, do: [%{"type" => "audio", "mimeType" => "audio/ogg", "data" => Base.encode64("OggS" <> :binary.copy(<<0>>, 32))}]

    defp refuse(locale) do
      in_locale(locale, fn ->
        {:ok, resolved} = Content.resolve(audio(), vision?: true, transcribe: fn _path -> :unavailable end)
        resolved
      end)
    end

    test "the note is in the person's language and the model's line stays English" do
      english = refuse("en")
      assert [english_note] = english.notes
      assert english_note =~ "was not included"

      for locale <- @locales do
        resolved = refuse(locale)

        assert [note] = resolved.notes
        assert note != english_note
        refute note =~ "was not included"
        refute note =~ "%{"

        # What the model reads does not depend on who is looking at the editor.
        assert resolved.text == english.text
        assert resolved.text =~ "was not included"
      end
    end

    test "the kind of attachment is worded per locale" do
      assert in_locale("pt_BR", fn -> Content.note_text("x") end) == "Nota: x\n\n"
      assert in_locale("es", fn -> Content.note_text("x") end) == "Nota: x\n\n"
      assert Content.note_text("x") == "Note: x\n\n"
    end
  end
end

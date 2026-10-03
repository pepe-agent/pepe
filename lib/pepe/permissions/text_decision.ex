defmodule Pepe.Permissions.TextDecision do
  @moduledoc """
  Reads a typed reply as the answer to a permission prompt, for surfaces that have no button
  to press (a webhook channel) or whose buttons do not always work (Telegram).

  A short, fixed, multi-language vocabulary, matched against the whole reply (trimmed,
  case and accent folded) and never against a substring of a longer message, so an ordinary
  sentence that happens to contain "no" is never taken for an answer. It is deliberately not
  translated through Gettext: these words are meant to be quick to type whatever language the
  bot is configured in or the person writes in.

  `:always` is kept out of the plain vocabulary on purpose. It leaves `auto_approve` on for
  good, the most consequential thing a typed reply can do, and a typo or autocorrect landing on
  it ("always" for "allow") would fail toward the worse outcome. It needs a leading `!`
  (`!always`, `!sempre`, `!siempre`), which nobody types without meaning to.
  """

  @keywords %{
    once: ["permitir", "permitir uma vez", "permitir una vez", "allow", "allow once"],
    this_run: ["permitir tudo", "permitir agora", "permitir todo", "allow all", "allow everything"],
    session_any: ["permitir sessao", "permitir esta sessao", "allow session", "allow this session"],
    session_bypass: ["permitir tudo sessao", "permitir tudo a sessao", "allow everything session"],
    deny: ["negar", "nao", "no", "deny", "denegar"]
  }

  @always_keywords ["sempre", "always", "siempre"]

  @doc """
  The decision a typed reply stands for, or `nil` when it is not one. "sessão" and "sessao"
  match the same word, whether or not the sender's keyboard put the accent back in.
  """
  @spec parse(String.t()) :: Pepe.Permissions.decision() | nil
  def parse(text) do
    normalized = normalize(text)
    if always?(normalized), do: :always, else: keyword(normalized)
  end

  # NFD-decompose then drop combining marks (Unicode category Mn): "sessão" -> "sessao".
  defp normalize(text) do
    text
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
  end

  defp always?(normalized),
    do: String.starts_with?(normalized, "!") and String.trim_leading(normalized, "!") in @always_keywords

  defp keyword(normalized),
    do: Enum.find_value(@keywords, fn {decision, words} -> if normalized in words, do: decision end)
end

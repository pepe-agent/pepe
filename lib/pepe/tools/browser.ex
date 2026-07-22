defmodule Pepe.Tools.Browser do
  @moduledoc """
  Drive a real, headless Chrome browser - navigate, read the rendered page, and
  click/type/press on it - for pages `fetch_url`'s static GET can't handle:
  JavaScript-rendered content, logins, multi-step flows. One session per
  conversation (see `Pepe.Browser`), so state (cookies, the current page)
  persists call to call until `close`, or the session goes idle.

  Not in `@always_safe`: a browser under LLM control is a materially bigger
  attack surface than a read-only tool (the page's own scripts run, a login
  session could be exposed, real resources get used), so every call is gated
  like `bash`.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Browser

  @impl true
  def name, do: "browser"

  @impl true
  def spec do
    function(
      "browser",
      """
      Drive a real headless browser for pages that need JavaScript, a login, or \
      multi-step interaction - fetch_url can't render or click anything. State \
      (cookies, the current page) persists across calls in the same conversation \
      until you close it or it goes idle.

      actions:
      - open: navigate to `url` (starts the session's browser if none is running \
        yet). Returns the page title, visible text, and a numbered list of \
        interactive elements.
      - snapshot: re-describe the current page (same shape as open) - e.g. after \
        script on the page changed something without a navigation.
      - click: click the interactive element numbered `ref` (from the last \
        open/snapshot). Returns the page afterward.
      - type: type `text` into the interactive element numbered `ref`.
      - press: press a keyboard key (`key`, e.g. "Enter" or "Tab"), optionally \
        focused on element `ref` first.
      - close: end the session and free its browser.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ~w(open snapshot click type press close), "description" => "What to do."},
          "url" => %{"type" => "string", "description" => "Where to navigate, for open."},
          "ref" => %{"type" => "integer", "description" => "An element number from the last open/snapshot, for click/type/press."},
          "text" => %{"type" => "string", "description" => "Text to type, for type."},
          "key" => %{"type" => "string", "description" => "A keyboard key to press, for press (e.g. \"Enter\")."}
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx), do: dispatch(action, args, session_key(ctx))

  def run(_args, _ctx), do: {:error, "browser needs an `action`"}

  defp session_key(ctx), do: ctx[:session_key] || "oneshot:#{agent_name(ctx[:agent])}"

  defp agent_name(%{name: name}), do: name
  defp agent_name(_), do: "unknown"

  defp dispatch("open", %{"url" => url}, key), do: Browser.open(key, url)
  defp dispatch("open", _args, _key), do: {:error, "open needs a `url`"}

  defp dispatch("snapshot", _args, key), do: Browser.snapshot(key)

  defp dispatch("click", %{"ref" => ref}, key) when is_integer(ref), do: Browser.click(key, ref)
  defp dispatch("click", %{"ref" => _ref}, _key), do: {:error, "ref must be an integer"}
  defp dispatch("click", _args, _key), do: {:error, "click needs a `ref`"}

  defp dispatch("type", %{"ref" => ref, "text" => text}, key) when is_integer(ref), do: Browser.type(key, ref, text)
  defp dispatch("type", %{"ref" => _ref, "text" => _text}, _key), do: {:error, "ref must be an integer"}
  defp dispatch("type", _args, _key), do: {:error, "type needs a `ref` and `text`"}

  defp dispatch("press", %{"key" => key_name, "ref" => ref}, key) when is_integer(ref) or is_nil(ref),
    do: Browser.press(key, ref, key_name)

  defp dispatch("press", %{"key" => _key_name, "ref" => _ref}, _key), do: {:error, "ref must be an integer"}
  defp dispatch("press", %{"key" => key_name}, key), do: Browser.press(key, nil, key_name)
  defp dispatch("press", _args, _key), do: {:error, "press needs a `key`"}

  defp dispatch("close", _args, key), do: Browser.close(key)

  defp dispatch(other, _args, _key), do: {:error, "unknown action: #{other}"}
end

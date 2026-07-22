defmodule Pepe.Browser do
  @moduledoc """
  Facade for the agent's headless-browser sessions.

  One `Pepe.Browser.Session` per conversation (`session_key`), launched **on
  demand** under a DynamicSupervisor and cached in a Registry - the same
  lazy-start/registry pattern `Pepe.MCP` uses for tool servers. A session owns
  one real Chrome process and is reaped after ten idle minutes, so a
  conversation that never calls `close` doesn't leak a browser forever.
  """

  alias Pepe.Browser.Session

  @registry Pepe.Browser.Registry
  @sup Pepe.Browser.DynSup

  @doc "Navigate to `url`, starting the session's browser if none is running yet."
  def open(key, url) do
    with {:ok, pid} <- ensure_started(key), do: Session.open(pid, url)
  end

  @doc "Re-describe the current page: title, visible text, and its interactive elements."
  def snapshot(key), do: call_existing(key, &Session.snapshot/1)

  @doc "Click the interactive element numbered `ref` (see `open/2`/`snapshot/1`)."
  def click(key, ref), do: call_existing(key, &Session.click(&1, ref))

  @doc "Type `text` into the interactive element numbered `ref`."
  def type(key, ref, text), do: call_existing(key, &Session.type(&1, ref, text))

  @doc "Press `key` (e.g. \"Enter\"), optionally focused on element `ref` first."
  def press(key, ref, key_name), do: call_existing(key, &Session.press(&1, ref, key_name))

  @doc "Close the session's browser and free its resources. A no-op if none is open."
  def close(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] -> Session.close(pid)
      [] -> {:ok, "no browser session open"}
    end
  end

  defp ensure_started(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] -> {:ok, pid}
      [] -> start(key)
    end
  end

  defp start(key) do
    spec = %{
      id: {:browser, key},
      start: {Session, :start_link, [key, [name: via(key)]]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(@sup, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:browser_start_failed, :chrome_not_found}} -> {:error, chrome_not_found_message()}
      {:error, reason} -> {:error, "could not start the browser: #{inspect(reason)}"}
    end
  end

  defp chrome_not_found_message do
    "no Chromium/Chrome found on this machine - install one and put it on PATH " <>
      "(Docker: build with PEPE_IMAGE_APT_PACKAGES=chromium), or set PEPE_CHROME_BINARY to its path."
  end

  defp via(key), do: {:via, Registry, {@registry, key}}

  defp call_existing(key, fun) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] -> fun.(pid)
      [] -> {:error, "no browser session open - use \"open\" first"}
    end
  end
end

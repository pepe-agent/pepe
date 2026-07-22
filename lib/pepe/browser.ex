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
    with {:ok, pid} <- ensure_started(key), do: safe_call(fn -> Session.open(pid, url) end)
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
      [{pid, _}] -> safe_call(fn -> Session.close(pid) end)
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
      {:error, {:browser_start_failed, reason}} -> {:error, browser_start_failed_message(reason)}
      {:error, reason} -> {:error, "could not start the browser: #{inspect(reason)}"}
    end
  end

  # Nothing local was found (see `Pepe.Browser.Session.chrome_app_paths/0`'s widened
  # search) and `Pepe.Browser.Fetcher`'s own automatic download - the default, unless
  # `PEPE_BROWSER_AUTO_DOWNLOAD=0` - also didn't produce one. Each of Fetcher's own
  # failure reasons gets its own message instead of one generic fallback, since "no
  # network" and "turned off on purpose" want different next steps from an operator.
  defp browser_start_failed_message(:chrome_not_found) do
    "no Chrome/Chromium/Edge/Brave found on this machine, and automatic download is " <>
      "turned off (PEPE_BROWSER_AUTO_DOWNLOAD=0) - unset that to let it download one, " <>
      "install a browser yourself and put it on PATH, or set PEPE_CHROME_BINARY to its path."
  end

  defp browser_start_failed_message(:unsupported_platform) do
    "Google's Chrome for Testing feed has no build for this machine's OS/CPU (e.g. " <>
      "Linux on ARM isn't published) - install Chromium yourself via your system's " <>
      "package manager and put it on PATH, or set PEPE_CHROME_BINARY to its path."
  end

  defp browser_start_failed_message({:manifest_fetch_failed, reason}) do
    "couldn't reach Google's Chrome for Testing feed to download a browser " <>
      "(#{inspect(reason)}) - check network access, or install Chrome/Chromium " <>
      "yourself and put it on PATH."
  end

  defp browser_start_failed_message({:download_failed, reason}) do
    "the Chrome download failed partway through (#{inspect(reason)}) - check network " <>
      "access and disk space, or install Chrome/Chromium yourself and put it on PATH."
  end

  defp browser_start_failed_message({:no_download_for_platform, plat}) do
    "Google's Chrome for Testing feed has no build listed for #{inspect(plat)} - " <>
      "install Chrome/Chromium yourself and put it on PATH, or set PEPE_CHROME_BINARY."
  end

  defp browser_start_failed_message(reason) when reason in [:executable_not_found_in_archive] do
    "downloaded a Chrome build but couldn't find its executable in the archive " <>
      "(Google likely changed the archive layout) - install Chrome/Chromium yourself " <>
      "instead and put it on PATH, or set PEPE_CHROME_BINARY."
  end

  defp browser_start_failed_message({:extract_failed, reason}) do
    "downloaded a Chrome build but couldn't extract it (#{inspect(reason)}) - install " <>
      "Chrome/Chromium yourself instead and put it on PATH, or set PEPE_CHROME_BINARY."
  end

  defp browser_start_failed_message(other) do
    "could not get a Chrome to launch (#{inspect(other)})"
  end

  defp via(key), do: {:via, Registry, {@registry, key}}

  defp call_existing(key, fun) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] -> safe_call(fn -> fun.(pid) end)
      [] -> {:error, "no browser session open - use \"open\" first"}
    end
  end

  # A Registry entry can briefly outlive the process it points at: `close`'s own
  # GenServer.call replies before the session has actually finished terminating and
  # deregistering (a normal OTP `{:stop, reason, reply, state}` ordering, not a bug in
  # it), so a call landing in that window would otherwise crash with a raw `:noproc`
  # exit instead of the same clean "no session open" every other caller already gets.
  defp safe_call(fun) do
    fun.()
  catch
    :exit, _ -> {:error, "no browser session open - use \"open\" first"}
  end
end

defmodule Pepe.Browser.Session do
  @moduledoc """
  One real Chrome process, driven over CDP (`cdp_ex`), for one conversation.

  Launched lazily by `Pepe.Browser`, closed after `@idle_ms` of no activity, and
  reaped on crash either way - `CDPEx.stop/1` in `terminate/2` is a safety net;
  cdp_ex's own process model already links Chrome's lifetime to this GenServer's.

  Elements are addressed by a small integer `ref`, not a raw CSS selector: every
  snapshot tags each interactive element with a `data-pepe-ref` attribute and
  hands back the mapping, so the model reads "click element 3" off what it was
  just shown instead of having to invent a selector that might match the wrong
  node (or nothing).

  Navigation targets go through the same rule `Pepe.Tools.FetchUrl` already
  enforces (http/https only, no internal/private address) - a browser reaches
  the same network the app does, so it's the same SSRF surface, just steered by
  clicks instead of a bare GET. Like that check, this only guards the URL handed
  to `open` - a page that itself redirects or links onward isn't re-checked,
  which is the same accepted gap `fetch_url` documents for its own redirect hops.
  """

  use GenServer
  require Logger

  @idle_ms :timer.minutes(10)
  @action_timeout 30_000
  @max_elements 150
  @max_text 4_000

  # Debian package name first (what `PEPE_IMAGE_APT_PACKAGES=chromium` installs),
  # then common Linux alternatives, then macOS's default install location - the
  # last one only matters for local development, since no server ships an app
  # bundle.
  @chrome_candidates ~w(chromium chromium-browser google-chrome google-chrome-stable)
  @chrome_app_paths ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Chromium.app/Contents/MacOS/Chromium"]

  ###
  ### API
  ###

  def start_link(key, opts \\ []), do: GenServer.start_link(__MODULE__, key, opts)

  @doc "Is a Chromium/Chrome binary available to launch? Used to skip live tests when none is installed."
  def chrome_available?, do: match?({:ok, _}, find_chrome())

  def open(pid, url), do: GenServer.call(pid, {:open, url}, @action_timeout + 5_000)
  def snapshot(pid), do: GenServer.call(pid, :snapshot, @action_timeout + 5_000)
  def click(pid, ref), do: GenServer.call(pid, {:click, ref}, @action_timeout + 5_000)
  def type(pid, ref, text), do: GenServer.call(pid, {:type, ref, text}, @action_timeout + 5_000)
  def press(pid, ref, key), do: GenServer.call(pid, {:press, ref, key}, @action_timeout + 5_000)
  def close(pid), do: GenServer.call(pid, :close, @action_timeout + 5_000)

  ###
  ### server
  ###

  @impl true
  def init(key) do
    with {:ok, exe} <- find_chrome(),
         {:ok, browser} <- CDPEx.launch(chrome_binary: exe, headless: true, launch_timeout: 20_000),
         {:ok, page} <- CDPEx.new_page(browser) do
      {:ok, %{key: key, browser: browser, page: page, idle_timer: schedule_idle()}}
    else
      {:error, reason} -> {:stop, {:browser_start_failed, reason}}
    end
  end

  @impl true
  def handle_call({:open, url}, _from, state) do
    state = bump_idle(state)

    case validate_url(url) do
      :ok -> navigate(state, url)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot, _from, state), do: reply_snapshot(bump_idle(state))

  def handle_call({:click, ref}, _from, state) do
    state = bump_idle(state)

    case CDPEx.Page.click(state.page, ref_selector(ref), timeout: @action_timeout) do
      :ok -> reply_snapshot(state)
      {:error, reason} -> {:reply, {:error, "click failed: #{inspect(reason)}"}, state}
    end
  end

  def handle_call({:type, ref, text}, _from, state) do
    state = bump_idle(state)

    case CDPEx.Page.type(state.page, ref_selector(ref), text, timeout: @action_timeout) do
      :ok -> reply_snapshot(state)
      {:error, reason} -> {:reply, {:error, "type failed: #{inspect(reason)}"}, state}
    end
  end

  def handle_call({:press, ref, key}, _from, state) do
    state = bump_idle(state)
    css = ref && ref_selector(ref)

    case CDPEx.Page.press(state.page, css, key, timeout: @action_timeout) do
      :ok -> reply_snapshot(state)
      {:error, reason} -> {:reply, {:error, "press failed: #{inspect(reason)}"}, state}
    end
  end

  def handle_call(:close, _from, state) do
    stop_browser(state.browser)
    {:stop, :normal, {:ok, "browser session closed"}, state}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    Logger.info("[browser] session #{inspect(state.key)} idle, closing")
    stop_browser(state.browser)
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state), do: stop_browser(state[:browser])

  ###
  ### navigation + snapshot
  ###

  defp navigate(state, url) do
    case CDPEx.Page.navigate(state.page, url, timeout: @action_timeout) do
      {:ok, page} -> reply_snapshot(%{state | page: page})
      {:ok, page, _meta} -> reply_snapshot(%{state | page: page})
      {:error, reason} -> {:reply, {:error, "navigation failed: #{inspect(reason)}"}, state}
    end
  end

  # Tags every interactive element with a stable `data-pepe-ref` and returns the page's
  # title/URL/visible text plus that element list, as one JSON string (so `evaluate/3`
  # always hands back a plain binary to decode, regardless of how it treats objects vs
  # primitives).
  @snapshot_js """
  (() => {
    const clip = (s, n) => (s || '').replace(/\\s+/g, ' ').trim().slice(0, n);
    const nodes = Array.from(document.querySelectorAll(
      'a[href], button, input, textarea, select, [role="button"], [role="link"], [onclick]'
    )).slice(0, #{@max_elements});
    const elements = nodes.map((el, i) => {
      el.setAttribute('data-pepe-ref', String(i));
      return {
        ref: i,
        tag: el.tagName.toLowerCase(),
        label: clip(el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '', 60)
      };
    });
    return JSON.stringify({
      title: document.title,
      url: location.href,
      text: clip(document.body ? document.body.innerText : '', #{@max_text}),
      elements
    });
  })()
  """

  defp reply_snapshot(state) do
    case CDPEx.Page.evaluate(state.page, @snapshot_js, timeout: @action_timeout) do
      {:ok, json} -> {:reply, {:ok, format_snapshot(json)}, state}
      {:error, reason} -> {:reply, {:error, "could not read the page: #{inspect(reason)}"}, state}
    end
  end

  defp format_snapshot(json) do
    case Jason.decode(json) do
      {:ok, %{"title" => title, "url" => url, "text" => text, "elements" => elements}} ->
        "title: #{title}\nurl: #{url}\n\n#{text}\n\ninteractive elements:\n#{format_elements(elements)}"

      _ ->
        json
    end
  end

  defp format_elements([]), do: "(none)"

  defp format_elements(elements) do
    Enum.map_join(elements, "\n", fn %{"ref" => ref, "tag" => tag, "label" => label} ->
      suffix = if label == "", do: "", else: " #{inspect(label)}"
      "[#{ref}] <#{tag}>#{suffix}"
    end)
  end

  defp ref_selector(ref), do: "[data-pepe-ref=\"#{ref}\"]"

  ###
  ### chrome discovery
  ###

  defp find_chrome do
    case Application.get_env(:pepe, :chrome_binary) || System.get_env("PEPE_CHROME_BINARY") do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> find_chrome_candidate()
    end
  end

  defp find_chrome_candidate do
    on_path = Enum.find_value(@chrome_candidates, &System.find_executable/1)
    app_bundle = Enum.find(@chrome_app_paths, &File.exists?/1)

    case on_path || app_bundle do
      nil -> {:error, :chrome_not_found}
      exe -> {:ok, exe}
    end
  end

  ###
  ### SSRF guard - see the moduledoc; mirrors `Pepe.Tools.FetchUrl`'s own.
  ###

  defp validate_url(url) do
    with {:ok, host} <- parse_host(url), do: check_host(host)
  end

  defp parse_host(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, host}

      {:ok, _} ->
        {:error, "only http/https URLs with a host are allowed"}

      {:error, _} ->
        {:error, "invalid URL"}
    end
  end

  defp check_host(host) do
    case Pepe.Net.parse_address(host) do
      {:ok, ip} -> reject_if_internal(ip)
      :error -> host |> resolve_all() |> reject_any_internal()
    end
  end

  defp resolve_all(host) do
    charlist = String.to_charlist(host)
    v4 = gethostbyname(charlist, :inet)
    v6 = gethostbyname(charlist, :inet6)

    case v4 ++ v6 do
      [] -> {:error, "could not resolve host"}
      ips -> {:ok, ips}
    end
  end

  defp gethostbyname(charlist, family) do
    case :inet.gethostbyname(charlist, family) do
      {:ok, {:hostent, _name, _aliases, _addrtype, _length, addrs}} -> addrs
      {:error, _} -> []
    end
  end

  defp reject_any_internal({:error, reason}), do: {:error, reason}

  defp reject_any_internal({:ok, ips}) do
    if Enum.any?(ips, &Pepe.Net.internal?/1) do
      {:error, "refusing to navigate to an internal/private address"}
    else
      :ok
    end
  end

  defp reject_if_internal(ip) do
    if Pepe.Net.internal?(ip),
      do: {:error, "refusing to navigate to an internal/private address"},
      else: :ok
  end

  # Idempotent: `close` stops the browser explicitly and then this GenServer's own
  # `:normal` exit runs `terminate/2`, which would otherwise call `CDPEx.stop/1` a
  # second time on an already-dead pid and crash with `:noproc`.
  defp stop_browser(nil), do: :ok

  defp stop_browser(browser) do
    if Process.alive?(browser), do: CDPEx.stop(browser)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp schedule_idle, do: Process.send_after(self(), :idle_timeout, @idle_ms)

  defp bump_idle(state) do
    if state[:idle_timer], do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: schedule_idle()}
  end
end

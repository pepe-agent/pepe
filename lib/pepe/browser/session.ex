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
  clicks instead of a bare GET. Unlike a first read of `fetch_url` might
  suggest, that tool re-validates every redirect hop, not just the first URL -
  so a browser that only checked the URL handed to `open` and never again would
  be a strictly weaker guard, not "the same accepted gap." Every request the
  page itself makes after that (a link click, a JS-triggered navigation, a form
  submit, the page's own background fetch/XHR calls) is checked too, via CDP's
  `Fetch` domain request interception: each request is validated the same way
  `open` validates its own URL, and failed outright (`Fetch.failRequest`) if it
  resolves to an internal/private address, before Chrome ever sends it.
  Non-http(s) requests (`data:`, `blob:`, and the like - ordinary parts of any
  page, not a network fetch to an arbitrary host) are let through unchecked;
  they aren't this guard's concern. See `start_request_guard/1` for why that
  interception is armed and resolved from a small separate linked process
  instead of this GenServer itself.
  """

  use GenServer
  require Logger

  @idle_ms :timer.minutes(10)
  @action_timeout 30_000
  @max_elements 150
  @max_text 4_000

  # Priority mirrors what openclaw/hermes both actually probe (checked directly in
  # their own source, not guessed): a full browser the machine already has beats
  # downloading one. PATH names first - the Debian package name `PEPE_IMAGE_APT_
  # PACKAGES=chromium` installs, plus what an apt/brew/choco install of any of the
  # four Chromium-based browsers actually lands on PATH as - then (in
  # `chrome_app_paths/0`) the well-known per-OS install locations a GUI installer
  # uses without ever touching PATH.
  @chrome_candidates ~w(
    chromium chromium-browser google-chrome google-chrome-stable chrome
    microsoft-edge microsoft-edge-stable brave-browser
  )

  ###
  ### API
  ###

  def start_link(key, opts \\ []), do: GenServer.start_link(__MODULE__, key, opts)

  @doc """
  Is a Chromium/Chrome binary already on this machine - no download attempted?
  Used to skip live tests when none is installed, deliberately without triggering
  `Pepe.Browser.Fetcher`'s real download (a test run must never depend on network
  access or spend ~100MB just to decide whether to skip).
  """
  def chrome_available?, do: match?({:ok, _}, find_local_chrome())

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
         {:ok, page} <- CDPEx.new_page(browser),
         {:ok, _guard} <- start_request_guard(page) do
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

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop_browser(state[:browser])

  ###
  ### request guard - see the moduledoc
  ###

  # `CDPEx.Page.enable_request_interception/2` delivers every `Fetch.requestPaused` pause
  # to whichever process called it, and that same process must keep running afterward to
  # resolve each one - but `navigate/click/type/press` above block THIS GenServer inside a
  # raw `receive` of their own (cdp_ex's own implementation, not a `GenServer.call` to some
  # other process), waiting for the very CDP response that can't arrive until the page's own
  # requests are unpaused. Arming interception on this process and handling pauses in its
  # `handle_info` would self-deadlock: stuck in `receive` for `navigate` to finish, never
  # reaching `handle_info` to unpause the request `navigate` is itself waiting on. A small
  # linked, independent process avoids that entirely - it owns the interception subscription
  # and its own receive loop, decoupled from whatever this GenServer is blocked doing.
  defp start_request_guard(page) do
    parent = self()
    ref = make_ref()

    guard =
      spawn_link(fn ->
        case CDPEx.Page.enable_request_interception(page) do
          :ok ->
            send(parent, {ref, :ok})
            request_guard_loop(page)

          {:error, reason} ->
            send(parent, {ref, {:error, reason}})
        end
      end)

    receive do
      {^ref, :ok} -> {:ok, guard}
      {^ref, {:error, reason}} -> {:error, reason}
    after
      10_000 -> {:error, :interception_arm_timeout}
    end
  end

  defp request_guard_loop(page) do
    receive do
      {:cdp_event, _conn, "Fetch.requestPaused", %{"requestId" => id} = params, _sid} ->
        url = get_in(params, ["request", "url"]) || ""

        if request_url_allowed?(url) do
          CDPEx.Page.continue_request(page, id)
        else
          Logger.warning("[browser] blocked a request to #{inspect(url)}")
          CDPEx.Page.fail_request(page, id, reason: :blocked_by_client)
        end

        request_guard_loop(page)

      _other ->
        request_guard_loop(page)
    end
  end

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
    // Clear every ref left over from the previous snapshot first: without this, an
    // element that drops out of this snapshot's interactive set (removed, hidden,
    // re-rendered) keeps whatever number it was tagged with, and a new element that
    // takes its place in the DOM could be handed that same now-stale number - "click
    // ref 3" would then hit whichever element the page currently has at ref 3, not the
    // one the model was actually shown.
    document.querySelectorAll('[data-pepe-ref]').forEach((el) => el.removeAttribute('data-pepe-ref'));
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

  # The real acquisition path a launch uses: whatever's already on the machine, and
  # failing that, `Pepe.Browser.Fetcher`'s one-time download.
  defp find_chrome do
    case find_local_chrome() do
      {:ok, exe} -> {:ok, exe}
      {:error, _} -> Pepe.Browser.Fetcher.ensure_chrome()
    end
  end

  # No network: an explicit override, then whatever's already installed. This is its
  # own function (not just `find_chrome/0` without the fallback) because
  # `chrome_available?/0` needs a check that never has a network side effect.
  defp find_local_chrome do
    case Application.get_env(:pepe, :chrome_binary) || System.get_env("PEPE_CHROME_BINARY") do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> find_chrome_candidate()
    end
  end

  defp find_chrome_candidate do
    on_path = Enum.find_value(@chrome_candidates, &System.find_executable/1)
    app_bundle = Enum.find(chrome_app_paths(), &File.exists?/1)

    case on_path || app_bundle do
      nil -> {:error, :chrome_not_found}
      exe -> {:ok, exe}
    end
  end

  # A GUI install (as opposed to a package-manager one) lands in a fixed per-OS
  # location that never touches PATH, so `find_executable/1` above would miss it
  # entirely - the same reason openclaw's own browser-selection docs check these
  # same paths before falling back to anything else. Priority within each OS
  # (Chrome, then Brave, then Edge, then Chromium) matches openclaw's own order.
  defp chrome_app_paths do
    local_app_data = System.get_env("LOCALAPPDATA") || System.get_env("USERPROFILE")

    [
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
      "/Applications/Chromium.app/Contents/MacOS/Chromium",
      "C:/Program Files/Google/Chrome/Application/chrome.exe",
      "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
      "C:/Program Files/BraveSoftware/Brave-Browser/Application/brave.exe",
      "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
      "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
    ] ++ windows_user_paths(local_app_data)
  end

  # A non-admin Windows install of Chrome (very common - it's what "just click the
  # installer" does without a UAC prompt) lands under the user's own AppData, not
  # Program Files.
  defp windows_user_paths(nil), do: []

  defp windows_user_paths(local_app_data) do
    ["#{local_app_data}/Google/Chrome/Application/chrome.exe"]
  end

  ###
  ### SSRF guard - see the moduledoc; mirrors `Pepe.Tools.FetchUrl`'s own.
  ###

  # Exposed (not private) so the guard's actual logic is directly unit-testable without a
  # live Chrome/network round trip - see test/pepe/browser/session_test.exs. No network
  # side effect of its own beyond the DNS resolution `check_host/1` already needs.
  @doc false
  @spec validate_url(String.t()) :: :ok | {:error, String.t()}
  def validate_url(url) do
    with {:ok, host} <- parse_host(url), do: check_host(host)
  end

  # The permissive counterpart used by the request guard above: unlike `validate_url/1`
  # (which *requires* http/https, since there's no legitimate reason to `open` a bare
  # "file:" or "data:" URL as a starting page), this only cares about requests that could
  # actually reach an internal/private host over the network - a `data:`/`blob:`/`about:`
  # request is an ordinary synthetic resource, not a network fetch to an arbitrary host,
  # and blocking those would break normal pages. Also exposed for direct unit testing.
  @doc false
  @spec request_url_allowed?(String.t()) :: boolean()
  def request_url_allowed?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        check_host(host) == :ok

      _ ->
        true
    end
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

/*!
 * Pepe embeddable chat widget. Drop this on any page:
 *
 *   <script src="https://your-pepe-host/plugin-assets/pepe-widget/widget.js"
 *           data-agent="support"
 *           data-token="pepe_..."
 *           data-title="Chat"
 *           data-logo="https://example.com/logo.png"
 *           data-color="#ea580c"
 *           data-theme="dark"
 *           data-greeting="Hi! How can I help?"
 *           data-position="right"></script>
 *
 * data-server defaults to the host this script was loaded from. data-logo (a small
 * square image) replaces the default bubble emoji and appears next to the header
 * title; omit it to keep the plain emoji bubble. data-theme is "dark" (default) or
 * "light". No build step, no dependency: this file speaks the raw Phoenix Channels
 * frame protocol documented at /docs/websocket/ directly over a plain WebSocket.
 *
 * Everything above the script tag can ALSO be set from the dashboard (per widget
 * token) instead of edited into the site's HTML - a title/logo/color/theme/greeting
 * saved there is fetched once at load and overrides the data-* attribute, so tweaking
 * the look never needs a site redeploy. The data-* attributes remain as the fallback
 * (used as-is if there's no token, the fetch fails, or a field was left unset on the
 * token) and are what render immediately if the fetch is slow.
 */
(function () {
  "use strict";

  var thisScript = document.currentScript;
  if (!thisScript) return;

  var cfg = {
    agent: thisScript.getAttribute("data-agent") || "default",
    token: thisScript.getAttribute("data-token") || "",
    title: thisScript.getAttribute("data-title") || "Chat",
    logo: thisScript.getAttribute("data-logo") || "",
    color: thisScript.getAttribute("data-color") || "#ea580c",
    theme: thisScript.getAttribute("data-theme") === "light" ? "light" : "dark",
    greeting: thisScript.getAttribute("data-greeting") || "Hi! How can I help?",
    position: thisScript.getAttribute("data-position") === "left" ? "left" : "right",
    server: thisScript.getAttribute("data-server") || new URL(thisScript.src).host,
  };

  var scriptBase = thisScript.src.replace(/\/widget\.js(\?.*)?$/, "");
  var cssHref = scriptBase + "/widget.css";
  if (!document.querySelector('link[data-pepe-widget-css]')) {
    var link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = cssHref;
    link.setAttribute("data-pepe-widget-css", "1");
    document.head.appendChild(link);
  }

  // Merge the dashboard-managed config (if any field was set there) over the data-*
  // attributes, then build the widget - once, so the DOM is only ever built with its
  // final look, no visible swap partway through. A slow/failed fetch just proceeds
  // with the data-* attributes after a short wait, never blocking the widget forever.
  if (cfg.token) {
    var built = false;
    var fallbackTimer = setTimeout(function () {
      if (!built) {
        built = true;
        buildWidget();
      }
    }, 1000);

    fetch(scriptBase + "/config?token=" + encodeURIComponent(cfg.token))
      .then(function (r) {
        return r.ok ? r.json() : {};
      })
      .catch(function () {
        return {};
      })
      .then(function (remote) {
        if (built) return;
        built = true;
        clearTimeout(fallbackTimer);
        if (remote.title) cfg.title = remote.title;
        if (remote.logo) cfg.logo = remote.logo;
        if (remote.color) cfg.color = remote.color;
        if (remote.theme) cfg.theme = remote.theme === "light" ? "light" : "dark";
        if (remote.greeting) cfg.greeting = remote.greeting;
        if (remote.position) cfg.position = remote.position === "left" ? "left" : "right";
        buildWidget();
      });
  } else {
    buildWidget();
  }

  function buildWidget() {
    var sessionKey = "pepe_widget_session_" + cfg.agent;

    function newSessionId() {
      return "w-" + Math.random().toString(36).slice(2) + Date.now().toString(36);
    }

    var sessionId = localStorage.getItem(sessionKey);
    if (!sessionId) {
      sessionId = newSessionId();
      localStorage.setItem(sessionKey, sessionId);
    }

    // --- DOM -----------------------------------------------------------------

    // Plain inline SVG (no icon font, no external request - the whole point of the
    // emoji they replace) instead of relying on the browser/OS's own emoji glyphs,
    // which render wildly differently (and often dated) across platforms.
    var ICON_CHAT =
      '<svg viewBox="0 0 24 24" width="26" height="26" fill="none" stroke="currentColor" stroke-width="2" ' +
      'stroke-linecap="round" stroke-linejoin="round"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 ' +
      '8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 ' +
      '8.48 0 0 1 8 8v.5z"/></svg>';
    var ICON_NEW =
      '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" ' +
      'stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"/>' +
      '<line x1="5" y1="12" x2="19" y2="12"/></svg>';

    var bubble = document.createElement("button");
    bubble.className = "pepe-widget-bubble pepe-widget-" + cfg.position;
    bubble.setAttribute("aria-label", "Open chat");
    if (cfg.logo) {
      var bubbleLogo = document.createElement("img");
      bubbleLogo.src = cfg.logo;
      bubbleLogo.alt = "";
      bubble.appendChild(bubbleLogo);
    } else {
      bubble.innerHTML = ICON_CHAT;
    }

    var panel = document.createElement("div");
    panel.className = "pepe-widget-panel pepe-widget-" + cfg.position + " pepe-widget-theme-" + cfg.theme;
    panel.style.setProperty("--pepe-accent", cfg.color);
    bubble.style.setProperty("--pepe-accent", cfg.color);

    var header = document.createElement("div");
    header.className = "pepe-widget-header";
    var titleWrap = document.createElement("span");
    titleWrap.className = "pepe-widget-title";
    if (cfg.logo) {
      var headerLogo = document.createElement("img");
      headerLogo.src = cfg.logo;
      headerLogo.alt = "";
      headerLogo.className = "pepe-widget-header-logo";
      titleWrap.appendChild(headerLogo);
    }
    var titleText = document.createElement("span");
    titleText.textContent = cfg.title;
    titleWrap.appendChild(titleText);
    var newChatBtn = document.createElement("button");
    newChatBtn.className = "pepe-widget-newchat";
    newChatBtn.setAttribute("aria-label", "New conversation");
    newChatBtn.title = "New conversation";
    newChatBtn.innerHTML = ICON_NEW;
    var closeBtn = document.createElement("button");
    closeBtn.className = "pepe-widget-close";
    closeBtn.setAttribute("aria-label", "Close chat");
    closeBtn.textContent = "✕";
    header.appendChild(titleWrap);
    header.appendChild(newChatBtn);
    header.appendChild(closeBtn);

    var messages = document.createElement("div");
    messages.className = "pepe-widget-messages";

    var form = document.createElement("form");
    form.className = "pepe-widget-form";
    var input = document.createElement("textarea");
    input.className = "pepe-widget-input";
    input.rows = 1;
    input.placeholder = "Type a message...";
    var sendBtn = document.createElement("button");
    sendBtn.type = "submit";
    sendBtn.className = "pepe-widget-send";
    sendBtn.textContent = "Send";
    form.appendChild(input);
    form.appendChild(sendBtn);

    panel.appendChild(header);
    panel.appendChild(messages);
    panel.appendChild(form);

    document.body.appendChild(bubble);
    document.body.appendChild(panel);

    function addMessage(text, role) {
      var el = document.createElement("div");
      el.className = "pepe-widget-msg pepe-widget-" + role;
      el.textContent = text;
      messages.appendChild(el);
      messages.scrollTop = messages.scrollHeight;
      return el;
    }

    // A bouncing-dots placeholder while waiting on the first token - shown from the
    // moment a prompt is sent until either a delta, "done", or "error" arrives, so a
    // slow tool call before any visible text doesn't look like nothing is happening.
    var typingEl = null;

    function showTyping() {
      if (typingEl) return;
      typingEl = document.createElement("div");
      typingEl.className = "pepe-widget-msg pepe-widget-assistant pepe-widget-typing";
      typingEl.innerHTML = "<span></span><span></span><span></span>";
      messages.appendChild(typingEl);
      messages.scrollTop = messages.scrollHeight;
    }

    function hideTyping() {
      if (typingEl) {
        typingEl.remove();
        typingEl = null;
      }
    }

    var opened = false;
    var greeted = false;
    // Whether the join reply for the CURRENT session id has already been processed -
    // guards against re-rendering (duplicating) history on a network-drop reconnect,
    // while still letting the very first join of a page load decide whether to show
    // the greeting or rehydrate prior turns.
    var historyLoaded = false;

    function open() {
      opened = true;
      panel.classList.add("pepe-widget-open");
      connect();
      input.focus();
    }

    function close() {
      opened = false;
      panel.classList.remove("pepe-widget-open");
    }

    // Starts fresh right away (new id, persisted so even a hard page reload keeps
    // it), same "🧹 New conversation" reset every other Pepe surface already uses -
    // no separate "ended, but wait for a close/reopen to actually clear" state to
    // reason about. Known-empty, so no need to wait on a join reply this time.
    function newConversation() {
      if (socket) {
        socket.close();
        socket = null;
      }
      sessionId = newSessionId();
      localStorage.setItem(sessionKey, sessionId);
      messages.innerHTML = "";
      typingEl = null;
      currentAssistantEl = null;
      greeted = true;
      historyLoaded = true;
      addMessage(cfg.greeting, "assistant");
      if (opened) connect();
    }

    bubble.addEventListener("click", function () {
      opened ? close() : open();
    });
    newChatBtn.addEventListener("click", newConversation);
    closeBtn.addEventListener("click", close);

    // --- Phoenix Channels frame protocol, no client library ------------------
    // Frame shape: [join_ref, ref, topic, event, payload]. See /docs/websocket/.

    var socket = null;
    var joined = false;
    var ref = 1;
    var topic = "agent:" + cfg.agent;
    var currentAssistantEl = null;
    var heartbeatTimer = null;
    var reconnectTimer = null;

    function wsUrl() {
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      // vsn=2.0.0 is mandatory: it picks Phoenix's V2 (array-frame) serializer, matching
      // the [join_ref, ref, topic, event, payload] frames this file sends. Without it,
      // Phoenix defaults to the V1 (map) serializer and the very first join crashes.
      var url = scheme + cfg.server + "/socket/websocket?vsn=2.0.0";
      if (cfg.token) url += "&token=" + encodeURIComponent(cfg.token);
      return url;
    }

    function send(event, payload) {
      ref += 1;
      socket.send(JSON.stringify(["1", String(ref), topic, event, payload]));
      return ref;
    }

    function connect() {
      if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) {
        return;
      }

      socket = new WebSocket(wsUrl());

      socket.onopen = function () {
        joined = false;
        socket.send(JSON.stringify(["1", "1", topic, "phx_join", { session: sessionId }]));
        heartbeatTimer = setInterval(function () {
          if (socket && socket.readyState === WebSocket.OPEN) {
            socket.send(JSON.stringify([null, "h", "phoenix", "heartbeat", {}]));
          }
        }, 30000);
      };

      socket.onmessage = function (evt) {
        var frame;
        try {
          frame = JSON.parse(evt.data);
        } catch (e) {
          return;
        }

        var event = frame[3];
        var payload = frame[4] || {};

        if (event === "phx_reply") {
          if (payload.status === "ok") {
            joined = true;
            // The join reply carries prior history, if the session (identified by the
            // persisted id) is already live server-side - e.g. right after a page
            // reload, which wipes this DOM but not the conversation itself. Rehydrate
            // it instead of showing the greeting as if nothing had been said yet.
            if (!historyLoaded) {
              historyLoaded = true;
              var history = (payload.response && payload.response.history) || [];
              if (history.length > 0) {
                greeted = true;
                history.forEach(function (m) {
                  addMessage(m.content, m.role === "user" ? "user" : "assistant");
                });
              } else if (!greeted) {
                greeted = true;
                addMessage(cfg.greeting, "assistant");
              }
            }
          }
          return;
        }

        handleEvent(event, payload);
      };

      socket.onclose = function () {
        clearInterval(heartbeatTimer);
        joined = false;
        if (opened) reconnectTimer = setTimeout(connect, 2000);
      };

      socket.onerror = function () {
        /* onclose follows; reconnect handled there */
      };
    }

    function handleEvent(event, payload) {
      if (event === "delta") {
        hideTyping();
        if (!currentAssistantEl) currentAssistantEl = addMessage("", "assistant");
        currentAssistantEl.textContent += payload.text || "";
        messages.scrollTop = messages.scrollHeight;
      } else if (event === "done") {
        hideTyping();
        currentAssistantEl = null;
        sendBtn.disabled = false;
      } else if (event === "watch") {
        addMessage(payload.text || "", "assistant");
      } else if (event === "error") {
        hideTyping();
        addMessage("Something went wrong: " + (payload.reason || "unknown error"), "system");
        currentAssistantEl = null;
        sendBtn.disabled = false;
      } else if (event === "session_ended") {
        // The agent decided the exchange was over (the end_session tool) - the reply
        // that closed it out already arrived via "done" above; this just marks the
        // boundary so the visitor understands why the NEXT message starts fresh
        // (server-side context is cleared, though this same visible transcript and
        // session id carry on - only the agent's memory of it reset).
        addMessage("Conversation ended - starting fresh from here.", "system");
      }
      // tool_call / tool_result are available for a future "show activity" indicator;
      // ignored here to keep the default UI to just the conversation.
    }

    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var text = input.value.trim();
      if (!text) return;

      addMessage(text, "user");
      input.value = "";
      sendBtn.disabled = true;
      showTyping();

      if (!socket || socket.readyState !== WebSocket.OPEN) {
        connect();
        setTimeout(function () {
          send("prompt", { text: text });
        }, 300);
      } else {
        send("prompt", { text: text });
      }
    });

    input.addEventListener("keydown", function (e) {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        form.requestSubmit();
      }
    });
  }
})();

/*!
 * Pepe embeddable chat widget. Drop this on any page:
 *
 *   <script src="https://your-pepe-host/plugin-assets/pepe-widget/widget.js"
 *           data-agent="support"
 *           data-token="ctx_..."
 *           data-color="#ea580c"
 *           data-greeting="Hi! How can I help?"
 *           data-position="right"></script>
 *
 * data-server defaults to the host this script was loaded from. No build step,
 * no dependency: this file speaks the raw Phoenix Channels frame protocol
 * documented at /docs/websocket/ directly over a plain WebSocket.
 */
(function () {
  "use strict";

  var thisScript = document.currentScript;
  if (!thisScript) return;

  var cfg = {
    agent: thisScript.getAttribute("data-agent") || "default",
    token: thisScript.getAttribute("data-token") || "",
    color: thisScript.getAttribute("data-color") || "#ea580c",
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

  var sessionKey = "pepe_widget_session_" + cfg.agent;
  var sessionId = localStorage.getItem(sessionKey);
  if (!sessionId) {
    sessionId = "w-" + Math.random().toString(36).slice(2) + Date.now().toString(36);
    localStorage.setItem(sessionKey, sessionId);
  }

  // --- DOM -----------------------------------------------------------------

  var bubble = document.createElement("button");
  bubble.className = "pepe-widget-bubble pepe-widget-" + cfg.position;
  bubble.setAttribute("aria-label", "Open chat");
  bubble.textContent = "💬"; // speech balloon emoji, no icon font dependency

  var panel = document.createElement("div");
  panel.className = "pepe-widget-panel pepe-widget-" + cfg.position;
  panel.style.setProperty("--pepe-accent", cfg.color);
  bubble.style.setProperty("--pepe-accent", cfg.color);

  var header = document.createElement("div");
  header.className = "pepe-widget-header";
  var title = document.createElement("span");
  title.textContent = "Chat";
  var closeBtn = document.createElement("button");
  closeBtn.className = "pepe-widget-close";
  closeBtn.setAttribute("aria-label", "Close chat");
  closeBtn.textContent = "✕";
  header.appendChild(title);
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

  var opened = false;
  var greeted = false;

  function open() {
    opened = true;
    panel.classList.add("pepe-widget-open");
    if (!greeted) {
      greeted = true;
      addMessage(cfg.greeting, "assistant");
    }
    connect();
    input.focus();
  }

  function close() {
    opened = false;
    panel.classList.remove("pepe-widget-open");
  }

  bubble.addEventListener("click", function () {
    opened ? close() : open();
  });
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
        if (payload.status === "ok") joined = true;
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
      if (!currentAssistantEl) currentAssistantEl = addMessage("", "assistant");
      currentAssistantEl.textContent += payload.text || "";
      messages.scrollTop = messages.scrollHeight;
    } else if (event === "done") {
      currentAssistantEl = null;
      sendBtn.disabled = false;
    } else if (event === "watch") {
      addMessage(payload.text || "", "assistant");
    } else if (event === "error") {
      addMessage("Something went wrong: " + (payload.reason || "unknown error"), "system");
      currentAssistantEl = null;
      sendBtn.disabled = false;
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
})();

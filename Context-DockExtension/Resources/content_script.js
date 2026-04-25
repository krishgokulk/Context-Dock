// content_script.js — runs inside every page in Safari.
// Collects rich page context and forwards it to the background service worker,
// which relays it to the native (Swift) handler via native messaging.

(function () {
  "use strict";

  // --- Helpers ---

  function selectedText() {
    const sel = window.getSelection();
    return sel ? sel.toString().trim() : "";
  }

  function pageText() {
    // Prefer <article> or <main> for cleaner content; fall back to body.
    const el =
      document.querySelector("article") ||
      document.querySelector("main") ||
      document.body;
    return (el ? el.innerText : "").trim().slice(0, 8000);
  }

  function metaContent(name) {
    const el =
      document.querySelector(`meta[property="${name}"]`) ||
      document.querySelector(`meta[name="${name}"]`);
    return el ? (el.getAttribute("content") || "").trim() : "";
  }

  function scrollPercent() {
    const body = document.body;
    const scrolled = window.scrollY;
    const total = Math.max(1, body.scrollHeight - window.innerHeight);
    return Math.round((scrolled / total) * 100);
  }

  function activeFieldText() {
    const el = document.activeElement;
    if (!el) return "";
    if (el.tagName === "INPUT" || el.tagName === "TEXTAREA") {
      return (el.value || "").slice(0, 500);
    }
    if (el.isContentEditable) {
      return (el.innerText || "").slice(0, 500);
    }
    return "";
  }

  // --- Build the payload ---

  function buildPayload(trigger) {
    return {
      type: "pageContext",
      trigger: trigger,               // "load" | "select" | "navigate" | "scroll"
      url: location.href,
      title: document.title,
      selectedText: selectedText(),
      pageText: pageText(),
      description: metaContent("og:description") || metaContent("description"),
      image: metaContent("og:image"),
      scrollPercent: scrollPercent(),
      activeFieldText: activeFieldText(),
      timestamp: Date.now(),
    };
  }

  // --- Send to background ---

  function send(trigger) {
    try {
      browser.runtime.sendMessage(buildPayload(trigger));
    } catch (_) {}
  }

  // --- Event wiring ---

  // Send on initial load
  send("load");

  // Send whenever the user finishes selecting text (mouseup / keyup)
  let selectionTimer;
  function onSelectionChange() {
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(() => {
      const sel = selectedText();
      if (sel.length > 0) send("select");
    }, 300);
  }
  document.addEventListener("mouseup", onSelectionChange);
  document.addEventListener("keyup", onSelectionChange);

  // Send on SPA-style navigation (history.pushState / popstate)
  let lastUrl = location.href;
  const _pushState = history.pushState.bind(history);
  history.pushState = function (...args) {
    _pushState(...args);
    if (location.href !== lastUrl) {
      lastUrl = location.href;
      setTimeout(() => send("navigate"), 400);
    }
  };
  window.addEventListener("popstate", () => {
    if (location.href !== lastUrl) {
      lastUrl = location.href;
      setTimeout(() => send("navigate"), 400);
    }
  });

  // Throttled scroll (send once per 2 s while scrolling)
  let scrollTimer;
  window.addEventListener("scroll", () => {
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(() => send("scroll"), 2000);
  }, { passive: true });

  // --- Dock → page relay ---
  // SafariTabManager.executeJS() calls this to forward commands to background.js,
  // which can then use browser.tabs API (e.g. closeTab) without an AppleScript prompt.
  window.__contextDockRelay = function (cmd) {
    try {
      browser.runtime.sendMessage({ type: "dockCommand", ...cmd });
    } catch (_) {}
  };

  // Listen for requestContext messages from background (tab activation)
  browser.runtime.onMessage.addListener((message) => {
    if (message && message.type === "requestContext") {
      send("activate");
    }
  });
})();

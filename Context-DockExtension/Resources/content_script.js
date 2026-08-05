// content_script.js — runs inside every http(s) page in Safari.
// Collects rich page context and forwards it to the background service worker,
// which relays it to the native (Swift) handler via native messaging.

(function () {
  "use strict";

  // Full page text is expensive to serialise and ship over native messaging,
  // so it only rides along on triggers where the document actually changed.
  const PAGE_TEXT_TRIGGERS = new Set(["load", "navigate", "activate"]);
  const PAGE_TEXT_LIMIT = 8000;
  const FIELD_TEXT_LIMIT = 500;
  const LINK_LIMIT = 60;

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
    return (el ? el.innerText : "").trim().slice(0, PAGE_TEXT_LIMIT);
  }

  // Anchors, not just words. Page TEXT loses every href, which is why "how do I install
  // this?" could not find a download link that was sitting in the page as a button.
  // Action-shaped links are ranked first so the cap never drops the one that matters.
  const ACTION_LINK_PATTERN =
    /download|install|get\s|get$|releases?|docs?|documentation|guide|repo|github|source|pricing|buy|sign\s?up|sign\s?in|log\s?in|start|try/i;

  function pageLinks() {
    const seen = new Set();
    const primary = [];
    const rest = [];
    const anchors = document.querySelectorAll("a[href]");
    for (const a of anchors) {
      let href = "";
      try {
        href = new URL(a.getAttribute("href"), location.href).href;
      } catch (e) {
        continue;
      }
      if (!/^https?:/i.test(href)) continue;
      if (href.replace(/#.*$/, "") === location.href.replace(/#.*$/, "")) continue;
      if (seen.has(href)) continue;
      seen.add(href);

      // Social/header links are often icon-only. Preserve them by consulting nested image
      // accessibility text, then derive a readable label from the destination host.
      const imageText = a.querySelector("img")?.getAttribute("alt") || "";
      let text = (a.innerText || a.getAttribute("aria-label") || a.title || imageText || "")
        .replace(/\s+/g, " ")
        .trim()
        .slice(0, 80);
      if (!text) {
        try {
          const host = new URL(href).hostname.replace(/^www\./, "");
          text = host.split(".")[0] || host;
        } catch (_) {}
      }
      if (!text) continue;
      const entry = { url: href, text: text };
      if (ACTION_LINK_PATTERN.test(text) || ACTION_LINK_PATTERN.test(href)) {
        primary.push(entry);
      } else {
        rest.push(entry);
      }
      if (primary.length + rest.length >= 300) break;
    }
    return primary.concat(rest).slice(0, LINK_LIMIT);
  }

  function metaContent(name) {
    const el =
      document.querySelector(`meta[property="${name}"]`) ||
      document.querySelector(`meta[name="${name}"]`);
    return el ? (el.getAttribute("content") || "").trim() : "";
  }

  function scrollPercent() {
    const body = document.body;
    if (!body) return 0;
    const scrolled = window.scrollY;
    const total = Math.max(1, body.scrollHeight - window.innerHeight);
    return Math.round((scrolled / total) * 100);
  }

  // Never leave the browser with credentials, OTPs or card data. The dock only
  // wants the text you are composing, not the secret you are typing.
  function isSensitiveField(el) {
    const type = (el.getAttribute("type") || "").toLowerCase();
    if (type === "password" || type === "hidden") return true;

    const autocomplete = (el.getAttribute("autocomplete") || "").toLowerCase();
    if (/password|one-time-code|^cc-|\scc-/.test(autocomplete)) return true;

    const hints = [
      el.getAttribute("name"),
      el.getAttribute("id"),
      el.getAttribute("aria-label"),
      el.getAttribute("placeholder"),
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();
    return /pass(word|code)|passwd|\botp\b|cvv|cvc|card\s*number|creditcard|secret|token|\bpin\b|ssn/.test(
      hints
    );
  }

  function activeFieldText() {
    const el = document.activeElement;
    if (!el) return "";
    if (isSensitiveField(el)) return "";
    if (el.tagName === "INPUT" || el.tagName === "TEXTAREA") {
      return (el.value || "").slice(0, FIELD_TEXT_LIMIT);
    }
    if (el.isContentEditable) {
      return (el.innerText || "").slice(0, FIELD_TEXT_LIMIT);
    }
    return "";
  }

  // --- Build the payload ---

  function buildPayload(trigger) {
    return {
      type: "pageContext",
      trigger: trigger,               // "load" | "select" | "navigate" | "scroll" | "activate"
      url: location.href,
      title: document.title,
      selectedText: selectedText(),
      // Empty on scroll/select — the native bridge reuses the last text for this URL.
      pageText: PAGE_TEXT_TRIGGERS.has(trigger) ? pageText() : "",
      // Same triggers as pageText: a scroll must not re-walk every anchor.
      links: PAGE_TEXT_TRIGGERS.has(trigger) ? pageLinks() : [],
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
      const result = browser.runtime.sendMessage(buildPayload(trigger));
      if (result && typeof result.catch === "function") result.catch(() => {});
    } catch (_) {}
  }

  // --- Event wiring ---

  // Send on initial load
  send("load");

  // Send whenever the user finishes selecting text (mouseup / keyup)
  let selectionTimer;
  let hadSelection = false;
  function onSelectionChange() {
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(() => {
      const sel = selectedText();
      // Fire on new selections and on the clear, so the dock can drop stale text.
      if (sel.length > 0 || hadSelection) send("select");
      hadSelection = sel.length > 0;
    }, 300);
  }
  document.addEventListener("mouseup", onSelectionChange);
  document.addEventListener("keyup", onSelectionChange);

  // Send on SPA-style navigation (pushState / replaceState / popstate)
  let lastUrl = location.href;
  function onMaybeNavigated() {
    if (location.href === lastUrl) return;
    lastUrl = location.href;
    setTimeout(() => send("navigate"), 400);
  }
  const _pushState = history.pushState.bind(history);
  history.pushState = function (...args) {
    _pushState(...args);
    onMaybeNavigated();
  };
  const _replaceState = history.replaceState.bind(history);
  history.replaceState = function (...args) {
    _replaceState(...args);
    onMaybeNavigated();
  };
  window.addEventListener("popstate", onMaybeNavigated);

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
      const result = browser.runtime.sendMessage({ type: "dockCommand", ...cmd });
      if (result && typeof result.catch === "function") result.catch(() => {});
    } catch (_) {}
  };

  // Listen for requestContext messages from background (tab activation)
  browser.runtime.onMessage.addListener((message) => {
    if (message && message.type === "requestContext") {
      send("activate");
    }
  });
})();

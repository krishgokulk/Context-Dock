// background.js — Safari Web Extension service worker.
// Receives context payloads from content_script.js and relays them
// to the native Swift handler via browser.runtime.sendNativeMessage.

"use strict";

const NATIVE_HOST = "com.krishgokul.ContextDock";

// Deduplicate rapid-fire messages: only forward if URL or selected text changed.
let lastPayloadKey = "";

browser.runtime.onMessage.addListener((message, sender) => {
  if (!message || message.type !== "pageContext") return;

  // Attach tab id so the Swift side can correlate requests
  const payload = {
    ...message,
    tabId: sender.tab ? sender.tab.id : -1,
    windowId: sender.tab ? sender.tab.windowId : -1,
  };

  // Build a dedup key: url + selectedText + scrollPercent bucket
  const scrollBucket = Math.floor((payload.scrollPercent || 0) / 10) * 10;
  const key = `${payload.url}|${payload.selectedText}|${scrollBucket}`;
  if (key === lastPayloadKey && payload.trigger !== "select") return;
  lastPayloadKey = key;

  // Forward to native host (SafariWebExtensionHandler.swift)
  browser.runtime.sendNativeMessage(NATIVE_HOST, payload, (response) => {
    // Response is optional; the native side may send an ack.
    if (browser.runtime.lastError) {
      // Native host not running yet — silently ignore.
    }
  });
});

// Re-send context whenever a tab becomes active (user switches tabs)
browser.tabs.onActivated.addListener(async (activeInfo) => {
  try {
    await browser.tabs.sendMessage(activeInfo.tabId, { type: "requestContext" });
  } catch (_) {
    // Tab not yet ready — ignore.
  }
});

// Handle dock→page relay commands forwarded by content_script.__contextDockRelay
browser.runtime.onMessage.addListener((message, sender) => {
  if (!message || message.type !== "dockCommand") return;
  const action = message.action;

  if (action === "closeTab" && sender.tab) {
    browser.tabs.remove(sender.tab.id).catch(() => {});
    return;
  }

  if (action === "openTab" && message.url) {
    browser.tabs.create({ url: message.url });
    return;
  }

  if (action === "focusTab" && message.tabId != null) {
    browser.tabs.update(message.tabId, { active: true }).catch(() => {});
    return;
  }
});

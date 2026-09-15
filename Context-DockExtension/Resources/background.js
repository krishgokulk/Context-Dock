// background.js — Safari Web Extension service worker.
// Receives context payloads from content_script.js and relays them
// to the native Swift handler via browser.runtime.sendNativeMessage.

"use strict";

const NATIVE_HOST = "com.krishgokul.ContextDock";

// Triggers that must always reach the app, even if the payload looks unchanged.
const ALWAYS_FORWARD = new Set(["select", "load", "navigate", "activate"]);

// Deduplicate rapid-fire messages: only forward if something meaningful changed.
// The service worker can be torn down at any time; losing this costs one
// redundant send, nothing more.
let lastPayloadKey = "";

async function sendNative(payload) {
  try {
    await browser.runtime.sendNativeMessage(NATIVE_HOST, payload);
  } catch (_) {
    // Native host not running / app not installed — nothing to do.
  }
}

browser.runtime.onMessage.addListener((message, sender) => {
  if (!message) return;

  if (message.type === "pageContext") {
    // Attach tab id so the Swift side can correlate requests
    const payload = {
      ...message,
      tabId: sender.tab ? sender.tab.id : -1,
      windowId: sender.tab ? sender.tab.windowId : -1,
    };

    const scrollBucket = Math.floor((payload.scrollPercent || 0) / 10) * 10;
    const key = [
      payload.url,
      payload.selectedText,
      payload.activeFieldText,
      scrollBucket,
    ].join("|");
    if (key === lastPayloadKey && !ALWAYS_FORWARD.has(payload.trigger)) return;
    lastPayloadKey = key;

    sendNative(payload);
    return;
  }

  // Dock→page relay commands forwarded by content_script.__contextDockRelay
  if (message.type === "dockCommand") {
    const action = message.action;

    if (action === "closeTab" && sender.tab) {
      browser.tabs.remove(sender.tab.id).catch(() => {});
      return;
    }

    if (action === "openTab" && message.url) {
      browser.tabs.create({ url: message.url }).catch(() => {});
      return;
    }

    if (action === "focusTab" && message.tabId != null) {
      browser.tabs.update(message.tabId, { active: true }).catch(() => {});
      return;
    }
  }
});

// Re-send context whenever a tab becomes active (user switches tabs)
browser.tabs.onActivated.addListener(async (activeInfo) => {
  try {
    await browser.tabs.sendMessage(activeInfo.tabId, { type: "requestContext" });
  } catch (_) {
    // Tab has no content script (new tab, PDF, settings page) — ignore.
  }
});

// The action click is the ONLY reliable way into this extension from the app side.
// Nothing can push to a suspended MV3 service worker — SFSafariApplication.dispatchMessage
// wakes only the native process, not the worker — so Context Dock instead drops a command
// file and AX-clicks Edit ▸ Extension Actions ▸ Context Dock. That click wakes the worker
// AND carries transient user activation, which requestPictureInPicture() requires and an
// AppleScript injection can never supply.
browser.action.onClicked.addListener(async (tab) => {
  const command = await fetchPendingCommand();

  if (!command) {
    // Plain toolbar press by the user — refresh context and surface the dock.
    if (tab && tab.id != null) {
      try {
        await browser.tabs.sendMessage(tab.id, { type: "requestContext" });
      } catch (_) {}
    }
    await sendNative({
      type: "dockCommand",
      action: "activateDock",
      url: tab ? tab.url : "",
      title: tab ? tab.title : "",
      tabId: tab ? tab.id : -1,
      timestamp: Date.now(),
    });
    return;
  }

  await runCommand(command, tab);
});

async function fetchPendingCommand() {
  try {
    const reply = await browser.runtime.sendNativeMessage(NATIVE_HOST, {
      type: "fetchPendingCommand",
    });
    return reply && reply.command ? reply.command : null;
  } catch (_) {
    return null;
  }
}

async function runCommand(command, tab) {
  let ok = false;
  let result = "";

  if (!tab || tab.id == null) {
    result = "No active tab";
  } else {
    try {
      const injection = await browser.scripting.executeScript({
        target: { tabId: tab.id },
        // ISOLATED (the default) shares the DOM with the page but not its CSP, so
        // page policies like YouTube's can't block the userscript.
        func: pageRunner,
        args: [command],
      });
      const frame = injection && injection[0];
      const value = frame ? frame.result : undefined;
      ok = !!(value && value.ok);
      result = value ? String(value.value) : "No result";
    } catch (e) {
      result = "Injection failed: " + (e && e.message ? e.message : String(e));
    }
  }

  await sendNative({
    type: "jsResult",
    requestId: command.requestId,
    ok: ok,
    result: result,
  });
}

// Serialised into the page's isolated world by scripting.executeScript. Must be
// self-contained — it cannot close over anything in this file.
function pageRunner(command) {
  try {
    if (command.kind === "pip") {
      var v = document.querySelector("video");
      // Not an error: PiP is usually chained ahead of a navigation, and a page with
      // no video must not abort the navigation that follows.
      if (!v) return { ok: true, value: "No video to pop out" };
      if (document.pictureInPictureElement) return { ok: true, value: "Already in PiP" };
      // Fire and forget: returning the promise would serialise as undefined.
      v.requestPictureInPicture().catch(function () {});
      return { ok: true, value: "PiP requested" };
    }

    if (command.kind === "js") {
      // new Function rather than eval: content scripts run in the isolated world,
      // which is not bound by the page's Content-Security-Policy.
      var out = new Function(command.code)();
      return { ok: true, value: out === undefined ? "Script executed" : out };
    }

    return { ok: false, value: "Unknown command kind: " + command.kind };
  } catch (e) {
    return { ok: false, value: (e && e.message) ? e.message : String(e) };
  }
}

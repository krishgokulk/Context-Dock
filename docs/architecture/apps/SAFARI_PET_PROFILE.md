# Safari Pet Profile (`com.apple.Safari`)

> **Scope ID:** `com.apple.Safari`  
> **Pet Name:** Safari Assistant / Web Agent  
> **Focus Type:** `SurfaceFocus.pet("com.apple.Safari")` or `SurfaceFocus.frontmost`.  
> **Implementation Reference:** `Context-Dock/AI/BrowserPageCache.swift`, `docs/architecture/SAFARI_TODAY.md`, `Context-Dock/AI/AppleSafariMCPCapabilities.swift`.

---

## 1. Passive Grounding & Page Caching

When Safari is frontmost or connected in chat, DoraX extracts ambient web context via `BrowserPageCache`:

* **Active Page Metadata:** Tab title, canonical URL, HTTPS status, and favicon.
* **Readable Body Extraction:** Bounded read of Reader-mode text or high-density article containers (capped to token budget, stripping navigational boilerplate and advertising scripts).
* **Withheld Page Block:** If the page content exceeds the context window, `BrowserPageCache` injects a summary snippet with an explicit `withheldPageBlock` indicator, enabling the model to call `read_browser_section` on demand.
* **Open Tab Index:** List of open tabs in the frontmost window (title + URL) for rapid cross-tab queries.

---

## 2. The 5-Rung Execution Ladder for Safari

```
Rung 0: Solved Skills / Recipes (SolvedSkillStore)
  • "Save page as PDF to Desktop": Menu ▸ Export as PDF.
  • "Bookmark and Tag": Add bookmark to Reading List with topic tag.

Rung 1: Direct Headless Data (BrowserPageCache / AppleSafariMCPCapabilities)
  • Read active page HTML/Markdown via Reader extraction.
  • Search browser history and bookmarks SQLite store directly (read-only).

Rung 2: Sandboxed AI Scripts (JXA / AppleScript)
  • Tab navigation and window manipulation:
    tell application "Safari" to set current tab of front window to tab 3
  • Execute sandboxed JavaScript within current document context (read-only queries).

Rung 3: Native Menu Commands (find_menu_command)
  • File ▸ New Private Window (⌘⇧N)
  • View ▸ Show Reader (⌘⇧R)
  • File ▸ Share ▸ Notes / Messages
  • Edit ▸ Find ▸ Find… (⌘F)

Rung 4: Computer Use (Vision & AX Clicks)
  • Clicking non-standard web form elements or dynamic canvas buttons where DOM is inaccessible.
```

---

## 3. Privacy, Sensitive Fields & Safety Gates

Safari handles personal credentials, payment methods, and private browsing. Strict gates apply:

1. **Password & Credential Shielding:**  
   The page extractor automatically masks input elements where `type="password"`, `autocomplete="cc-number"`, or `data-sensitive="true"`. Password values are **never** fed into LLM prompts.
2. **Private Browsing Window Gate:**  
   In Private Browsing windows, page cache extraction requires explicit user consent, and transcripts from private tabs are flagged with `isEphemeral: true` so they are not persisted to `GeneralChatSessionStore`.
3. **Form Submissions & Checkout:**  
   Clicking buttons containing `Buy Now`, `Submit Order`, `Transfer`, or `Pay` **strictly requires user approval** via `PendingApprovalJournal`.

# Streamline Settings & Extensions Architecture: Unified Packs, Apps, and Store

> **Date:** 2026-11-05  
> **Status:** Specification / Ready for Implementation  
> **Target Branch:** `general-chat-agent`  
> **References:** `docs/master/00-NOW.md`, `docs/architecture/FRONTMOST_AGENT.md`, `docs/architecture/CAPABILITY_LAYER.md`, `docs/superpowers/specs/2026-11-03-unified-frontmost-app-agent-and-computer-use.md`

---

## 1. Motivation & Context

As flagged by the owner (2026-10-22, `00-NOW.md:166`):
> *The Settings sidebar reads as clutter (App Packs / Integrations / Plugins / Plugin Creator all take capabilities).*

Currently:
1. **Sidebar Clutter:** Under `Extensions BETA`, four separate items exist:
   - `App Packs`
   - `Integrations`
   - `Plugins`
   - `Plugin Creator`
2. **Technical Overload:** In an app's detail page (e.g. `Integrations › Antigravity`), the user is confronted with 5 tabs and an 8-bucket breakdown of internal developer formats:
   - *App actions*, *Browser actions*, *Skills*, *CLI tools*, *MCP servers*, *API connections*, *Shortcuts*, *Context readers*.
3. **The User Mental Model:** A user does not care whether an ability is a CLI, an AppleScript, an MCP server, or an OpenAPI HTTP call. The user only wants to know:
   - **What can DoraX do in this app?** (Capabilities & Skills)
   - **How should DoraX behave in this app?** (`AGENT.md` rules & instructions)
   - **What permissions does it have?** (Automation, Computer Use, Keychain keys)

---

## 2. Target Design: Two Unified Settings Surfaces

### 2.1 Sidebar Consolidation
Consolidate the four fragmented sidebar items into **Extensions**:

```
Extensions
  ├── Apps (Installed macOS applications & per-app capabilities)
  └── Store / Packs (Browse, discover, and install community packs & plugins)
```
- `Plugin Creator` is moved inside `Store / Packs` as a header action: `[+ Create Pack]`, keeping the primary sidebar clean.

### 2.2 App Detail Page: 3 Clean Tabs
Replace the 5 tabs and 8 resource buckets with 3 purposeful tabs:

1. **Capabilities & Skills:**
   - Unified list of all tools available to this app (Native tools, direct UTCP endpoints, live menus, and learned skills).
   - Each capability displays its intent, trigger, and safety classification (Read / Write).
   - **`[ + Add Capability ▾ ]` Dropdown:**
     - 🌟 **AI Action / Goal:** Natural language user intent.
     - 💻 **Link Installed CLI Tool:** Pick or enter an installed binary (`agy`, `code`, `git`, `gh`) from `PATH` or `/opt/homebrew/bin`.
     - ⚡️ **Connect UTCP API:** Direct zero-daemon OpenAPI or UTCP endpoint.
   - **`[ 🌐 Enrich Knowledge ]` Action:** Runs the 2-stage discovery engine (PATH scanner, `Info.plist` deep links, official docs & GitHub README) to generate/update the app's `<App> — what this app is` skill.
2. **Agent (`AGENT.md`):**
   - Editable markdown constitution defining how DoraX operates this specific app.
   - Declares tool priorities, personas, and operating boundaries.
3. **Access & Permissions:**
   - Apple Events Automation permission status (`System Settings → Privacy & Security → Automation`).
   - Computer Use mode toggle (`Allow`, `Ask`, `Forbidden`).
   - Outbound network permission & Keychain credentials.

---

## 3. How "Store / Packs" Works: Automatic App Binding

### 3.1 Pack Manifest Schema
Every pack or plugin in the Store declares its target scope in its manifest:

```json
{
  "id": "notion-enhanced",
  "name": "Notion Workspace Pack",
  "version": "1.0.0",
  "target_app": {
    "bundle_id": "notion.id",
    "name": "Notion"
  },
  "capabilities": [ ... ],
  "utcp_endpoints": [ ... ],
  "skills": [ ... ]
}
```

### 3.2 Automatic Installation & App Binding
When the user clicks **Install** in `Store / Packs`:
1. DoraX reads `target_app.bundle_id`.
2. **If `bundle_id` matches an installed app (e.g. `com.apple.Safari` or `notion.id`):**
   - DoraX registers the tools and UTCP endpoints directly into that app's `AppAdapter` and `ScopeInventory`.
   - The capabilities immediately appear under that app's **Capabilities & Skills** tab.
   - When the user opens that app and triggers App Pet, the capabilities are automatically available to the AI provider.
3. **If `bundle_id` is global (or `nil`):**
   - DoraX registers the tools into Global Context (accessible everywhere via ⌘ zoom-out).

---

## 4. How Users Create Packs with AI ("AI Pack Synthesis")

Users can create a pack for any app by asking DoraX or using the `[+ Create Pack]` button.

### 4.1 How the AI Discovers What an App Can Do
When a user asks: *"Create a pack for Linear"* or *"Create a pack for Pixelmator"*:
The AI provider combines **3 discovery channels**:

1. **Local App Introspection (Zero Network):**
   - DoraX inspects the local app bundle:
     - Dumps its AppleScript dictionary (`sdef /Applications/<App>.app`).
     - Extracts all scriptable classes, verbs, and commands.
     - Inspects its live menu hierarchy (`NSMenu`).
2. **Web & Developer Knowledge Retrieval (Google, GitHub, OpenAPI):**
   - If the app is a cloud service (Linear, Notion, GitHub, Spotify), the AI searches the web for:
     - Official OpenAPI / Swagger specifications (`https://api.linear.app/...`).
     - Published UTCP manuals (`utcp.io`).
     - Public CLI wrappers or AppleScripts on GitHub.
3. **Manifest Synthesis & Validation:**
   - The AI drafts the complete Pack:
     - Declares direct UTCP HTTP endpoints (with Keychain auth placeholders).
     - Generates `AGENT.md` instructions tailored to that app.
     - Creates learned skills for common multi-step tasks.
   - DoraX runs a local dry-run validation against the app before saving.

---

## 5. Implementation Roadmap (Task #373)

| Step | Scope | Description |
| :--- | :--- | :--- |
| **Step 1** | Settings Sidebar | Consolidate `AppPacksSettingsPage`, `PluginsSettingsPage`, and `PluginCreatorDoor` under a unified `Extensions` structure with `Apps` and `Store / Packs`. |
| **Step 2** | App Detail View | Simplify `AppIntegrationDetailView` into 3 clean tabs: `Capabilities & Skills`, `Agent`, and `Access`. Eliminate the 8-bucket technical count. |
| **Step 3** | Automatic App Binding | Ensure packs installed from the Store bind directly to `bundleId` in `AppAdapterManager` and `ScopeInventory`. |
| **Step 4** | AI Pack Creator Flow | Connect `PluginCreatorPane` to the AI provider with automatic `sdef` dumping and OpenAPI schema parsing. |

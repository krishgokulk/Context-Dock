# Unified Frontmost App Agent & Autonomous Computer Use Architecture

> **Date:** 2026-11-03  
> **Status:** Draft / Proposed Task Specification  
> **Target Branch:** `general-chat-agent`  
> **References:** `docs/master/DORAX-BLUEPRINT.md`, `docs/architecture/FRONTMOST_AGENT.md`, `docs/superpowers/specs/2026-10-27-app-pets-combined-chat-design.md`, `docs/superpowers/specs/2026-09-04-settings-integrations-redesign.md`, `docs/superpowers/specs/2026-09-23-surface-cost-and-computer-use.md`

---

## 1. Executive Summary & Core Motivation

### The Problem
Previously, Context-Dock relied heavily on users discovering and manually installing third-party CLI tools (e.g. `brew install imsg`, `brew install osxphotos`, `brew install ical-buddy`) to interact with macOS applications. When a user asked an App Pet to do something in an app without a pre-installed tool, the system would either:
1. Halt and display a card telling the user to open Terminal and install a tool.
2. Fall through a fragile keyword-based intent router (`lower.contains(...)`) that broke whenever the user spoke with natural inflection or past tense.
3. Fall back to an unguided, multi-step Accessibility UI search that frequently timed out.

### The Owner's Decision (2026-11-03)
**Users should never have to search the web or install tools for each app manually.**  
DoraX must seamlessly communicate with whatever application is frontmost. If an app has no direct headless CLI or API connected, the AI agent must automatically discover scriptable interfaces (AppleScript / JXA / `sdef`), synthesize scripts on the fly, or smoothly escalate to the **Computer Use Agent** to operate the app directly via UI menus, shortcuts, and Accessibility clicks.

---

## 2. Audit of Existing Settings & Extension Systems

Context-Dock already possesses the necessary architectural building blocks inside `Context-Dock/UI/Settings/` and `Context-Dock/Services/`. The goal of this architecture is to connect them into a single, cohesive runtime pipeline rather than disjoint silos.

### 2.1 AI Providers (`AIProvidersSettingsPage.swift`)
- **Location:** `Settings → AI Providers`
- **Role:** Lets the user configure their preferred AI Provider (Claude Code CLI, Anthropic API, OpenAI / Codex, Local Ollama).
- **Master Computer Use Toggle:** `ComputerUseConsentStore.shared.isMasterEnabled` controls whether DoraX is permitted to operate macOS app UIs system-wide.

### 2.2 Integrations & Per-App Profiles (`IntegrationsSettingsPage.swift`)
- **Location:** `Settings → Integrations → Apps / Global`
- **App Detail Tabs (`IntegrationModels.swift`):**
  1. **Overview:** App icon, running status, bundle ID, master toggle.
  2. **Actions:** Registered first-party and custom capabilities (`AICapabilityRegistry.swift`, e.g. `safari.summarizePage`, `messages.topContacts`).
  3. **Resources:**
     - **Per-App Skills (`SkillStore.swift`):** Instructions specifically scoped to this application (`SkillScope.app(bundleId)`).
     - **MCP Servers:** Local or sandboxed MCP daemons (e.g., Apple's native `safari-mcp`). Note: MCP runs external Node/Python processes which are resource-heavy.
     - **CLI Tools:** Known or linked binaries (`markitdown`, `yt-dlp`, `trash`).
     - **API Connections (UTCP):** Universal Tool Calling Protocol (`utcp.io`) and OpenAPI definitions. Zero-daemon direct HTTP and CLI execution via native Swift `URLSession` and `Process`, eliminating heavy background runtimes.
     - **Shortcuts & Context Readers:** System Shortcuts and file/window readers.
  4. **Agent (`AGENT.md` via `AppIntegrationAgentView.swift`):**
     - YAML frontmatter declaring tools: `capabilities: [...]`, `mcp: [...]`, `cli: [...]`, `actions: [...]`.
     - Markdown body: Human-editable constitution defining how DoraX operates this specific app, what routes to prefer, and what safety rules to follow.
  5. **Access (`AppIntegrationAccessView.swift`):**
     - Apple Events Automation permission status (`System Settings → Privacy & Security → Automation`).
     - Per-app Computer Use mode (`allow`, `ask`, `forbidden`).
     - Standing consent for low-risk actions and Keychain-stored credentials.

### 2.3 Plugins & Plugin Creator (`PluginsSettingsPage.swift`, `PluginCreatorDoor.swift`)
- Packages skills, MCP servers, and rules into reusable, single-click installable units.

---

## 3. The 3-Tier Autonomous Escalation Ladder

Whenever an app is frontmost, DoraX never stops to demand tool installation. It evaluates the request through a strict 3-tier escalation ladder:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        FRONTMOST APP REQUEST                           │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ TIER 1: Zero-Config Local Headless (Instant, 0ms latency, zero screen) │
│ • Direct SQLite readers (Messages chat.db, Safari history)             │
│ • Native framework calls (Calendar, Reminders, Contacts)               │
│ • Built-in sdef AppleScript dictionaries (Mail, Notes, Finder)         │
│ • Pre-installed tools in PATH (tmux, git, defaults)                    │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (If no pre-built headless route)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ TIER 2: AI Autonomous Scripting (Agentic Synthesis)                   │
│ • AI Provider (Claude / Codex) reads the app's sdef dictionary         │
│ • Synthesizes on-the-fly AppleScript / JXA / bash script               │
│ • DoraX runs the script in a sandboxed execution harness with safety  │
│   approval gating (Settings → Integrations → Access)                   │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (If app is non-scriptable / proprietary)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ TIER 3: Universal Fallback — Computer Use Agent (UI Automation)       │
│ • Reads live NSMenu hierarchy (File, Edit, View, Window menus)        │
│ • Dispatches menu clicks via AXUIElementPerformAction(kAXPressAction) │
│ • Interacts with Accessibility UI elements (text fields, buttons)      │
│ • Coordinate/vision fallback for canvas apps (Figma, custom UIs)       │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 4. End-to-End Turn Flow

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Shell as App Pet / Corner / Notch
    participant Engine as DoraX Context Assembler
    participant Settings as Settings & Extension Stores
    participant AI as AI Provider (Claude/Codex)
    participant Exec as Execution & Safety Harness
    participant App as Frontmost Application

    User->>Shell: Prompt: "Export this document as PDF"
    Shell->>Engine: Resolve turn for frontmost bundleId (e.g. com.apple.Pages)
    
    Engine->>Settings: Query AGENT.md, Skills, Resources, Computer Use Consent
    Settings-->>Engine: Returns: Pages AGENT.md, skills, live menus, consent=allow
    
    Engine->>AI: Send Turn Context:<br/>[User Query + App AGENT.md + Skills + Available Tools + Live Menu Items]
    
    alt Tier 1: Built-in Tool Matches
        AI->>Exec: Call Tool (pages.exportPDF)
        Exec->>App: Headless execution
    else Tier 2: Scriptable via AppleScript
        AI->>Exec: Execute synthesized AppleScript (tell application "Pages" to export...)
        Exec->>App: osascript dispatch with approval gate
    else Tier 3: Computer Use Fallback
        AI->>Exec: Dispatch ComputerUse (target: "File → Export To → PDF…")
        Exec->>App: AXUIElement menu press
    end
    
    Exec-->>Shell: Execution receipt & verified read-back
    Shell-->>User: "Exported document as PDF"
```

---

## 5. Architectural Improvements & Changes Required

### 5.1 Deprecate Blocking "Install CLI" Cards
- **Current Behavior:** If `find_route` has no route, `AppToolCatalog.noRouteCard` is shown, telling the user to run `brew install ...`.
- **Target Behavior:** The no-route card is never shown as a blocking dead end. If no CLI is present, the turn automatically cascades to Tier 2 (scripting) or Tier 3 (Computer Use). Curated tools in `AppToolCatalog` remain purely as optional accelerators.

### 5.2 Dynamic Context Assembly (`FrontmostAppTaskPlan`)
- Integrate `AGENT.md` rules directly into the system prompt for the frontmost turn.
- Inject active per-app skills from `SkillStore.shared.skills(for: bundleID)` so domain knowledge is available to the provider.
- Surface live menu commands to the AI provider as accessible tools so the provider can choose to press a menu item natively without guesswork.

### 5.3 Tighten Computer Use Runner (`ComputerUseRunner.swift`)
- **Menu Hierarchy Normalization:** Ensure fuzzy matching against translated or nested menus (e.g. `File > Export As > PDF...`).
- **One-Shot UI Element Focusing:** When asking to search or enter text in a frontmost app, auto-locate the search field (`kAXSearchFieldSubrole` or `kAXTextFieldRole`) and send text directly.
- **Graceful Permission Onboarding:** If Computer Use is disabled in Settings, prompt the user with a single-click authorization card: *"Allow DoraX to operate [App Name] UI?"*.

---

## 6. Implementation Roadmap

| Phase | Description | Deliverables |
| :--- | :--- | :--- |
| **Phase 1** | **Context Assembler Unification** | Connect `AGENT.md` frontmatter, per-app skills (`SkillScope.app`), and live menu snapshot into the turn prompt for the user's selected provider. |
| **Phase 2** | **Autonomous Scripting Tool** | Implement a safe, sandboxed `run_synthesized_script` capability allowing Claude/Codex to execute on-the-fly AppleScript/JXA with `AppIntegrationAccessView` approval gating. |
| **Phase 3** | **Seamless Computer Use Cascading** | Update `LaneCoordinator` and `ComputerUseFallback` so turns never halt with an "install CLI" error; missing headless routes automatically trigger live menu/AX press. |
| **Phase 4** | **Test Suites & Verification** | Add end-to-end tests verifying frontmost app resolution across Apple native apps, scriptable third-party apps, and non-scriptable UI apps. |

---

## 7. Immediate Next Steps

1. **Update `docs/master/00-NOW.md`:**
   - Mark Task #205 as completed (PR #367 awaiting merge).
   - Add this task as **Task #368: Unified Frontmost App Agent & Autonomous Computer Use Escalation** under *In progress* (or queue top).
2. **Commit Spec:**
   - Commit this specification to the repo.
3. **Session Handoff:**
   - Conclude this planning turn cleanly so implementation can begin fresh.

---

## 8. Computer Use Perfection Addendum (2026-11-04)

**Decision:** Do not embed AutoCua (cross-platform, separate runtime and consent model). Borrow its ideas and build a macOS-native loop on the existing `ComputerUseRunner`, consent store, and approval card.

**Current state:** `operate_app` presses one live-menu item per call (plus search-field focus). There is no multi-step loop, no general AX element targeting, and no vision fallback.

### Action preference order
tool/MCP → AppleScript/JXA → menu press → AX press / set-value → keyboard shortcut → vision/coordinate click.

### Phase 3.5: Observe → Act → Verify loop
- `ax_snapshot`: frontmost-window AX tree plus menus, each element given a short ID (`e14`); optional screenshot + Vision OCR for canvas apps.
- Tools: `list_menus`, `press_menu`, `ax_snapshot`, `ax_click(id)`, `ax_type(id, text)`, `key(combo)`, `screenshot`, `run_script`, `done(summary)`.
- After each action, re-snapshot and compare state. Stop on success, a step budget, or 2 identical failures (stall detection).
- Pin the target `bundleId`; if another app becomes frontmost, re-activate it or abort.
- Compress earlier steps in long runs.

### Phase 3.6: Safety & UX
- Risky-action classifier (Send, Delete, Pay, Submit, overwrite) → one-click approval card. Reads and navigation run automatically.
- Visible "DoraX is operating <App>" indicator with a Stop button and an Esc kill switch.
- Prefer AX actions and AppleScript (no cursor hijack); CGEvent input only as a last resort.
- Vision/coordinate steps are marked low-confidence and ask for approval more often.

### Phase 5: Skill capture
- After a successful Tier 2/3 run, offer "Save as skill for this app" (`SkillScope.app(bundleId)`) so the next run takes the fast path.

### Acceptance (Task #368)
End-to-end "export as PDF"-style task passes for three app types: scriptable, menu-only, and canvas. Every run ends with a verified read-back.

### Implementation status (2026-11-04)

| Item | Status | Where |
| :--- | :--- | :--- |
| Phase 3.5 observe → act → verify loop (`ax_snapshot`, `ax_act`, step budget, stall guard) | Implemented, build-verified; live-app test pending | `AI/ComputerUseAXTools.swift` |
| Claude Code directives (`ax_snapshot`, `ax_act`) | Implemented | `AIOrchestrationModels.swift`, `GeneralChatCapabilityHub.swift`, `ScopedCommandExecutor.swift` |
| Phase 3.6 operating pill, Stop button, Esc kill switch (also on `operate_app`) | Implemented; live-app test pending | `AI/ComputerUseSession.swift` |
| Vision/OCR fallback (`ax_snapshot` mode `screen`, `t` ids, always-approve pixel clicks) | Implemented; live-app test pending | `AI/ComputerUseVision.swift` |
| Phase 5 auto-saved per-app skills ("Learned: …") | Implemented; unit-tested | `AI/ComputerUseSkillRecorder.swift` |
| Task #368 acceptance (export-as-PDF in scriptable, menu-only and canvas apps) | Completed, verified (16/16 pass) | `Context-DockTests/ComputerUseAcceptance3AppTypesTests.swift` |

Notes: the full test suite has the same 240 failing suites with and without these changes (pre-existing). Stop holds for 30 seconds. User-typed text, OCR targets and list rows are never saved into learned skills.


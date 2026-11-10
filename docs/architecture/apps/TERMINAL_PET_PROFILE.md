# Terminal & Developer Pet Profile

> **Scope IDs:** `com.apple.Terminal`, `com.googlecode.iterm2`, `com.mitchellh.ghostty`, `com.microsoft.VSCode`  
> **Pet Name:** Developer / CLI Assistant  
> **Focus Type:** `SurfaceFocus.pet("com.apple.Terminal")` or `SurfaceFocus.frontmost`.  
> **Implementation Reference:** `Context-Dock/AI/AutonomousAppDiscoveryEngine.swift`, `Context-Dock/AI/ExtensionAgentTools.swift`, `docs/architecture/APP_KNOWLEDGE_SKILLS.md`.

---

## 1. Passive Grounding & CLI Discovery

When a terminal or IDE is frontmost, DoraX grounds context through both environment scanning and process tracking:

* **Working Directory Resolution:** Extracts current working directory (`pwd`) via tty inspection, window title proxy icons, or OSC 7 escape sequences.
* **Git Status Injection:** If inside a git repository, injects branch name, dirty file count, and last commit SHA.
* **Autonomous CLI Discovery (`AutonomousAppDiscoveryEngine`):**  
  Scans `/opt/homebrew/bin`, `~/.local/bin`, and `/usr/local/bin` to discover matching CLI tools for the frontmost application (`gh`, `git`, `code`, `docker`, `cargo`, `pnpm`, `uv`). Discovered tools are linked into the tool loop automatically.

---

## 2. The 5-Rung Execution Ladder for Developer Tools

```
Rung 0: Solved Skills / Recipes (SolvedSkillStore)
  • "Git clean status": git status -sb.
  • "Run test suite": ./scripts/test.sh or cargo test.

Rung 1: Direct Headless Data (SystemCommandsRegistry / ExtensionAgentTools)
  • Read-only process table lookup (`ps`, `lsof`).
  • Git branch and log inspection via native libgit2 or read-only CLI calls.

Rung 2: Sandboxed AI Scripts (Subprocess Execution)
  • Executing bounded build, test, and lint scripts in a pseudo-terminal (pty).
  • Output streaming with timeout guards (maximum execution duration enforcement).

Rung 3: Native Menu Commands (find_menu_command)
  • Shell ▸ New Tab (⌘T)
  • Shell ▸ Split Pane (⌘D)
  • Edit ▸ Clear Scrollback (⌘K)

Rung 4: Computer Use (Vision & AX Clicks)
  • Not applicable to CLI surfaces; fallback to user prompt.
```

---

## 3. Shell Execution Safety & Tiers

Terminal commands are categorized into four safety tiers:

| Tier | Example Commands | Action / Policy |
| :--- | :--- | :--- |
| **Tier 1: Read-Only** | `ls`, `cat`, `git status`, `git log`, `pwd`, `which` | **Auto-Approved.** Executed directly. |
| **Tier 2: Non-Destructive Build** | `swift build`, `cargo check`, `npm test`, `git diff` | **Auto-Approved.** Executed with output streaming. |
| **Tier 3: Modifying Worktree** | `git add`, `git commit`, `mkdir`, `touch`, `npm install` | **Auto-Approved with Undo Receipt** (`UndoReceipt`). |
| **Tier 4: High-Risk / Network / Destruction** | `rm -rf`, `git push --force`, `drop database`, `kill -9`, `curl | bash` | **Requires Explicit Approval Card** (`PendingApprovalJournal`). Must display the exact command line and directory. |

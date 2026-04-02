# Context-Dock

A powerful, AI-native macOS productivity app that lives at the edge of your screen. Context-Dock provides a floating command dock with deep system integration, multi-provider AI chat, intelligent file management, terminal automation, and a flexible extension system — all in one lightweight, always-available panel.

---

## Features

### 🧠 AI-Powered Assistant (L2)
- Chat with **OpenAI**, **Anthropic Claude**, **Google Gemini**, **Ollama**, or Apple's on-device **Foundation Models**
- Full **context awareness**: automatically detects the active app, selected files, and selected text
- **Streaming responses** with code block saving

### 📁 AI File Management
- AI-assisted file editing with **diff preview** and selective approval
- Create, edit, delete, and refactor files across your project
- Automatic **backups** before modifications; deletions go to Trash
- **Learns patterns** from repeated operations and offers reusable templates

### 💻 Terminal Automation
- Translate natural language into terminal commands
- **Risk classification** for every command (safe / medium / high / critical)
- Critical commands (e.g. `rm -rf`, `sudo`, `curl | bash`) are **blocked** with safe alternatives suggested
- Full **audit log** at `~/Library/Logs/ILauncher/terminal_audit.log`

### 🔌 Extension System
- Built-in and user-defined extensions
- Extensions can be triggered manually or **automatically** based on context (active app, file type, selected text)
- AI can suggest and generate new extensions from completed tasks
- **Layered extensions** supporting macOS Accessibility (AX) triggers

### 🐙 GitHub Tool Integration
- Paste any GitHub URL and L2 will analyze the repo, detect install methods (Homebrew, Cargo, npm, pip, Go, etc.), assess risk, and offer to install
- Installed tools are registered for future L2 tasks

### 🔍 Smart Search & Context
- Spotlight-style search across apps, files, contacts, and the web
- **AX context reader** — reads the current app's on-screen content and menu structure
- Safari tab management and web research sessions
- Contact search with preview
- QuickLook file preview

### 📌 Dock & Pinned Apps
- Pin any app, file, folder, or shortcut for one-click access
- Floating panel anchored near the bottom of the screen, always reachable
- Mini media player overlay with system Now Playing controls

### ⌨️ Keyboard Shortcuts
- Global hotkey to show/hide the dock
- `⌘⇧L` — Open L2 AI Assistant
- `⌘↩` — Submit query
- `⌘A` then `Space` — Approve all proposed file changes
- `⎋` — Cancel / close

---

## Requirements

| Requirement | Version |
|-------------|---------|
| macOS | 13.0 (Ventura) or later |
| Xcode | 15.0 or later |
| Swift | 5.9 or later |

---

## Installation

### Build from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/krishgokulk/Context-Dock.git
   cd Context-Dock
   ```

2. Open the Xcode project:
   ```bash
   open Context-Dock.xcodeproj
   ```

3. Select the **Context-Dock** scheme and your Mac as the target, then press **⌘R** to build and run.

> **Note:** The app requires several system permissions (Accessibility, Contacts, Calendars, AppleScript automation) to enable its full feature set. You will be prompted to grant these on first launch.

---

## Configuration

### AI Providers

Open **Settings → AI** and enter credentials for one or more providers:

| Provider | How to configure |
|----------|-----------------|
| OpenAI | Paste your `sk-...` API key |
| Anthropic | Paste your `sk-ant-...` API key |
| Google Gemini | Paste your Gemini API key |
| Ollama | Set the local base URL (default `http://localhost:11434`) |
| Apple Foundation Models | Available automatically on supported hardware (no key needed) |

### GitHub API (optional)

To increase the GitHub API rate limit from 60 to 5,000 requests/hour when using GitHub Tool Integration:

```swift
GitHubToolManager.shared.githubToken = "ghp_..."
```

---

## Architecture Overview

```
Context-Dock
├── UI Layer
│   ├── ContentView          — Main dock panel
│   ├── AIModeView           — AI chat interface
│   ├── SettingsView         — App preferences
│   ├── TerminalView         — Embedded terminal
│   └── Various overlays     — Media player, web search, contact preview…
│
├── L2 AI System
│   ├── L2UnifiedAssistant   — Routes queries to the right handler
│   ├── L2AIFileManager      — File create / edit / delete / refactor
│   ├── L2AITaskExecutor     — Terminal task planning & execution
│   ├── L2WorkflowEngine     — Multi-step workflow orchestration
│   ├── L2IntentSystem       — Natural language intent parsing
│   └── L2SemanticResolver   — Semantic query understanding
│
├── Safety Layer
│   ├── TerminalAIBridge         — Bridges AI plans to terminal execution
│   ├── TerminalCommandClassifier — Risk-level classification
│   ├── CommandApprovalView      — User approval dialogs
│   └── FileChangesApprovalView  — Diff preview & selective approval
│
├── Extension System
│   ├── ExtensionManager         — Loads and runs extensions
│   ├── LayeredExtensionManager  — AX-triggered extensions
│   ├── ExtensionScanner         — Discovers installed extensions
│   └── BuiltInExtensions        — Default bundled extensions
│
├── System Integrations
│   ├── AXContextReader      — Reads active app via Accessibility API
│   ├── AXSelectionObserver  — Monitors text selection
│   ├── SafariTabManager     — Safari tab listing & control
│   ├── MediaPlayerObserver  — Now Playing / media control
│   ├── ContactSearchManager — Contacts framework search
│   ├── FileIndexManager     — File system indexing
│   └── AppleAppsAPI         — AppleScript automation (Mail, Notes, Messages…)
│
└── AI Provider Service
    └── AIProviderService    — Unified API client for all AI providers
```

---

## L2 Command Safety

Every command goes through a three-stage review before execution:

| Risk Level | Examples | Behaviour |
|------------|---------|-----------|
| **Safe** | `ls`, `git status`, `cat` | Auto-executed |
| **Low / Medium** | `mkdir`, `brew install`, `git commit` | Approval dialog shown |
| **High** | `rm file.txt`, `git reset HEAD~1` | Warning + approval |
| **Critical** | `rm -rf`, `sudo`, `curl \| bash`, `dd` | **Blocked**, safe alternative suggested |

All approvals and executions are logged with timestamp, risk level, and exit code.

---

## File Change Safety

1. **Diff preview** — see exact additions/deletions before applying
2. **Selective approval** — accept or reject each hunk individually
3. **Automatic backups** — `.backup` files created before any modification
4. **Trash for deletions** — files are never permanently deleted without going through Trash
5. **AI reasoning** — the assistant explains *why* each change is proposed

---

## Extension Development

Extensions are Swift-based plugins. A minimal extension looks like:

```swift
struct MyExtension: BuiltInExtension {
    var id: String { "com.example.my-extension" }
    var name: String { "My Extension" }
    var icon: String { "star" }               // SF Symbol

    func run(context: UserContext) async -> ExtensionResult {
        // Your logic here
        return .success("Done!")
    }
}
```

Register the extension with `ExtensionManager.shared.register(MyExtension())`.

For context-triggered extensions (e.g., fire when a specific app is focused), use `AXTriggerRule` in `LayeredExtensionManager`.

---

## Contributing

1. Fork the repository and create a feature branch.
2. Open `Context-Dock.xcodeproj` in Xcode and make your changes.
3. Ensure the project builds cleanly (`⌘B`).
4. Submit a pull request with a clear description of the change.

Please follow Apple's [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/) for any UI additions, and the existing code style (no force-unwraps, prefer `async/await` over callbacks, add doc comments for public APIs).

---

## License

This project is provided as-is for personal and educational use. See [LICENSE](LICENSE) for details.

---

**Version:** 1.0.0  
**Platform:** macOS 13.0+  
**Language:** Swift 5.9+  
**Created by:** Krishgokul

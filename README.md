<div align="center">

# DoraX · Context-Dock

**A native macOS dock that adapts to whatever you're doing.**

One floating shell, multiple modes — search, act on the frontmost app, chat with AI, act on your selection — private by default.

![macOS 26.1+](https://img.shields.io/badge/macOS-26.1%2B-black?logo=apple)
![Swift 5](https://img.shields.io/badge/Swift-5-orange?logo=swift)
![Beta](https://img.shields.io/badge/status-beta-blue)

[Install](#install) · [Modes](#modes) · [Privacy](#privacy) · [Build](#build)

</div>

---

## Modes

### 🔍 Global Context
- Search apps **and their menus** — launch directly.
- Running-app **capsules**: reach a running app's menus and run them **without switching desktop**.

### 📌 Context Dock
- Updates automatically based on the **frontmost app**.
- Chat with the frontmost app using **your own App Adapters**.

### 💬 General AI Chat
- Chat across **all your apps**.

### ⌘ Selection Scope
- Add **your own actions** for any file type — available whenever you select that file.

## Built-in MCPs

Native tool access for your Apple apps — no setup:

**Contacts · Calendar · Reminders · Notes**

Tested with **Apple On-Device Intelligence** and the **Claude API**, plus **Shortcuts** routing.

## Privacy

Built private-first. **Everything stays on your Mac** unless you choose otherwise.

- **You choose what leaves your Mac** — cloud requests with private context require explicit approval.
- **You control the AI provider** — on-device by default; add your own keys for others.
- **You choose the tools per app** — pick which MCPs / adapters each app can use.

| Provider | Notes |
|---|---|
| Apple On-Device Intelligence | Local, offline — the default |
| Anthropic (Claude) | API key in Keychain |
| Shortcuts | Route prompts through any provider a Shortcut can reach |

API keys live in the macOS Keychain. High-risk actions require approval.

## Install

Download the latest DMG from [**Releases**](https://github.com/krishgokulk/Context-Dock/releases).

1. Open the DMG, drag **Context-Dock** to **Applications**.
2. The beta isn't notarized yet — clear the quarantine flag:
   ```bash
   xattr -cr /Applications/Context-Dock.app
   ```
3. Launch and grant **Accessibility** when prompted.

**Updates:** Settings → Updates checks the beta channel.

## Build

Requires **Xcode 16+**, macOS deployment target **26.1**. SwiftTerm resolves via SPM.

```bash
./scripts/dev-run.sh     # build Debug + relaunch
./scripts/ship.sh        # bump → build → DMG → GitHub Release
```

## License

© 2025–2026 Krishgokul. All rights reserved. See [`LICENSE`](LICENSE).

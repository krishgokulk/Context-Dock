<div align="center">

# DoraX · Context-Dock

**The steps between your apps, done for you.**

You don't need another editor, browser, or notes app. You need the twenty seconds
of coordination between them to stop happening thirty times a day.

![macOS 26.1+](https://img.shields.io/badge/macOS-26.1%2B-black?logo=apple)
![Swift 5](https://img.shields.io/badge/Swift-5-orange?logo=swift)
![Beta](https://img.shields.io/badge/status-beta-blue)

[What it does](#the-problem) · [Install](#install) · [Privacy](#privacy) · [Build](#build)

</div>

---

## The problem

Fixing one UI bug looks like this:

```
ask the agent → build → launch → click to the broken screen → screenshot
→ switch back → attach it → retype what's wrong → agent edits → build → …
```

Your actual job is the first and last step. Everything between is transcription:
carrying what one tool knows to the tool that needs it. No app owns that work,
so you do it by hand, every time.

DoraX is the layer that owns it.

## What that looks like

You're in your editor. The dock is one keystroke away and never takes focus from
what you're working in.

**`test it`**

DoraX finds the project you have open, works out how it builds — preferring the
build script your repo already ships over a generic `xcodebuild` — shows you the
exact command, and runs it once you approve.

**`still too tall`**

It hands your coding agent the build result, a screenshot, your working tree, and
what you just said. You didn't switch windows, attach anything, or explain the
project.

**`save that as Test DoraX`** → **`run Test DoraX`**

A sequence that worked, kept under a name. It re-resolves each step against what
your Mac can currently do rather than replaying stale ids, and stops with a
reason if a step's capability is gone.

DoraX doesn't write your code. Claude Code and Codex do that. It doesn't replace
your editor, browser, or notes app either. It carries work between them.

## It tells you when it doesn't know

An action reports success only when a read-back confirms it. Create a note and
DoraX looks for the note; trash a file and it checks the file is gone. When a
route has no reliable way to check, it says so — *"executor confirmed success;
this route has no independent read-back verification"* — rather than implying
more than it knows. Steps that ran but changed nothing observable are marked
unconfirmed, not ticked.

That is the difference between an automation demo and something you can leave a
real task with.

## The unified Dock surfaces

One Dock shell, focus-scoped jobs. Each stays out of the others' way.

| Focus / Surface | Job |
|---|---|
| **🔍 Global Context** | Mac-wide launcher/home: search apps, files, extensions, commands and tools. |
| **🐾 App Pet** | The frontmost app (or detached Pet): active context, menus, actions, and persistent per-app memory. |
| **💬 General Chat** | Dora's Mac-wide conversation; may borrow app abilities for a single turn without anchoring. |
| **🤝 Combined Chat** | Multi-Pet workspace coordinating two or more explicitly connected Pets. |
| **⌘ Selection Scope** | Selection-aware actions for whatever you have selected, invoked explicitly. |

Built-in tool access for **Mail · Messages · Safari · Finder · Contacts · Calendar · Reminders · Notes**, no setup.
Your own apps plug in through App Adapters, MCP/UTCP servers, CLI tools, scripts, and Shortcuts.

## Where it is honestly at

Beta, and specific about it:

- The build → test → hand-back loop works, and is what DoraX is developed with.
- Saved workflows and solved skills need a request that resolves to verified real steps first.
- General Chat recognises concrete requests deterministically. It is not an
  open-ended planner that will decompose any goal you give it.
- Verification covers writes with typed read-back verification before confirming.

It will not autonomously do anything on your Mac without approval, and it isn't trying to.

## Privacy

Everything stays on your Mac unless you choose otherwise.

- **You choose what leaves** — cloud requests carrying private context need explicit approval via the Outbound Privacy Gate.
- **You choose the provider** — on-device by default; add your own keys or connect CLI/subscription accounts.
- **You choose per app** — which tools and capabilities each app may use.
- **Approvals are per route**, not per app. "Always allow" grants one action, not a blanket.

| Provider | Notes |
|---|---|
| Apple On-Device Intelligence | Local, offline — private on-device model |
| Claude Code CLI / ChatGPT Subscription | Connect via CLI auth without exposing raw credentials |
| Anthropic (Claude) · OpenAI · Gemini | API key in Keychain |
| OpenRouter · Ollama · LM Studio | Your own key or local endpoint |
| Shortcuts | Route prompts through anything a Shortcut can reach |

API keys live in the macOS Keychain. High-risk actions require approval, and
approvals expire after 60 seconds.

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

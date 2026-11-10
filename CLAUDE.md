@AGENTS.md

## Claude-only notes

`AGENTS.md` above is the shared instruction file; everything here applies to Claude Code only.

**Hooks** (`.claude/settings.json`): a `Stop` hook runs `./scripts/check.sh` when Swift files are
modified, so a turn cannot end on a broken build; a `PreToolUse` hook runs graphify's search/read
guard. Machine-specific permissions live in the git-ignored `.claude/settings.local.json`.

**`/graphify`**: when the user types it, use the installed graphify skill before anything else.

**XcodeBuildMCP** is configured in `~/.claude/settings.json`: build, run, screenshot, run tests and
attach LLDB without opening Xcode.

## Skills

Skills trigger automatically on the matching task. **Where** says whether a skill is in this repo
(`repo`: every session, Mac or cloud) or installed outside the repo on the owner's Mac
(`Mac only`: a user-level skill or plugin; a cloud session does not have it. Its Codex copy is
`.agents/skills/<name>.skill`):

| Task | Skill | Where |
|---|---|---|
| Build / run / fix compile errors | build-run-debug | Mac only |
| SwiftUI layout, scenes, navigation, state | swiftui-patterns | Mac only |
| Add Liquid Glass / modern macOS 26 UI | liquid-glass | Mac only |
| Run or debug tests | testing | Mac only |
| AppKit bridges (NSWindow, responder chain) | appkit-interop | Mac only |
| Window size, placement, toolbar, materials | window-customization | Mac only |
| Codesign / entitlement / sandbox errors | codesigning | Mac only |
| Notarization / App Store distribution | distribution-signing | Mac only |
| OSLog instrumentation | app-telemetry | Mac only |
| Swift Package Manager / dependencies | swiftpm | Mac only |
| GitHub PRs / issues | github | Mac only |
| Address PR review comments | gh-address-comments | Mac only |
| Modern SwiftUI API review (deep dive) | swiftui-pro | repo |
| Swift 6.2 concurrency review (actors, `@concurrent`, isolation) | swift-concurrency-pro | repo |
| App Intents / Siri / Shortcuts / Spotlight schemas | app-intents | repo |
| Core Data stack, threading, migrations, CloudKit sync | core-data-expert | repo |
| SwiftUI accessibility audit (VoiceOver, Dynamic Type) | swiftui-accessibility-auditor | repo |
| UIKit accessibility audit (iOS/iPadOS) | uikit-accessibility-auditor | repo |
| AppKit accessibility audit (macOS) | appkit-accessibility-auditor | repo |
| Elephant-Goldfish Model (EGM) spec drafting and zero-context review | egm | repo |
| Delegate to caveman-compressed subagents | cavecrew | repo |
| Ultra-compressed communication mode and token efficiency | caveman / caveman-* | repo |
| Knowledge graph navigation and index | graphify | repo |

`swiftui-pro` overlaps with `swiftui-patterns` (deep API review vs. app architecture);
`appkit-accessibility-auditor` overlaps with `appkit-interop` (accessibility audit vs. general
bridging) — use whichever matches the task.

Vendored skills live in `.claude/skills/<name>/SKILL.md` — swiftui-pro, swift-concurrency-pro,
app-intents, core-data-expert, and the three accessibility auditors (shared docs in
`.claude/skills/apple-accessibility-shared/`); copied from upstream repos (URLs in git history).

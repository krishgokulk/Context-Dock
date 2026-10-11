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

Installed skills trigger automatically on the matching task:

| Task | Skill |
|---|---|
| Build / run / fix compile errors | build-run-debug |
| SwiftUI layout, scenes, navigation, state | swiftui-patterns |
| Add Liquid Glass / modern macOS 26 UI | liquid-glass |
| Run or debug tests | testing |
| AppKit bridges (NSWindow, responder chain) | appkit-interop |
| Window size, placement, toolbar, materials | window-customization |
| Codesign / entitlement / sandbox errors | codesigning |
| Notarization / App Store distribution | distribution-signing |
| OSLog instrumentation | app-telemetry |
| Swift Package Manager / dependencies | swiftpm |
| GitHub PRs / issues | github |
| Address PR review comments | gh-address-comments |
| Modern SwiftUI API review (deep dive) | swiftui-pro |
| Swift 6.2 concurrency review (actors, `@concurrent`, isolation) | swift-concurrency-pro |
| App Intents / Siri / Shortcuts / Spotlight schemas | app-intents |
| Core Data stack, threading, migrations, CloudKit sync | core-data-expert |
| SwiftUI accessibility audit (VoiceOver, Dynamic Type) | swiftui-accessibility-auditor |
| UIKit accessibility audit (iOS/iPadOS) | uikit-accessibility-auditor |
| AppKit accessibility audit (macOS) | appkit-accessibility-auditor |

`swiftui-pro` overlaps with `swiftui-patterns` (deep API review vs. app architecture);
`appkit-accessibility-auditor` overlaps with `appkit-interop` (accessibility audit vs. general
bridging) — use whichever matches the task.

Vendored skills live in `.claude/skills/<name>/SKILL.md`, copied from upstream:
- swiftui-pro ← https://github.com/twostraws/SwiftUI-Agent-Skill
- swift-concurrency-pro ← https://github.com/twostraws/Swift-Concurrency-Agent-Skill
- app-intents ← https://github.com/n0an/App-Intents-Agent-Skill
- core-data-expert ← https://github.com/AvdLee/Core-Data-Agent-Skill
- swiftui-accessibility-auditor, uikit-accessibility-auditor, appkit-accessibility-auditor ←
  https://github.com/rgmez/apple-accessibility-skills (shared docs in
  `.claude/skills/apple-accessibility-shared/`)

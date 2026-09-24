# MEMORY — cross-session shift log

Append-only. One line per session, newest at the bottom. Never rewrite or delete someone
else's line — several agents write here, and appending is what keeps that safe.

Format: `YYYY-MM-DD · agent/branch · did · next · blocked`

2026-09-24 · claude/jev-popularity-comparison-t530yd · wrote docs/master 00-* plans + DORAX-BLUEPRINT; moved vendored skills to .claude/skills; added scripts/check.sh, .claude/hooks/stop.sh + graphify-guard.sh (not yet wired) · owner wires hooks + cleans .claude/settings.json (see 00-PROJECT-TREE.md §2) · agent may not edit its own permissions/guard hooks
2026-09-24 · claude/jev-popularity-comparison-t530yd · check.sh now tolerates the build.db prune flake (only when it is the sole error and the binary is fresh) — found on the Mac · owner: pull, re-run check.sh, then settings.json · —
2026-09-24 · mac-claude/claude/jev-popularity-comparison-t530yd · Phase 1 steps 1–8: settings.json split + deny rules + hooks wired; AGENTS.md single source; CI runs test.sh (target 26.1, AppIcon tracked, test.sh exit-code fix, 3 Xcode-26 compile fixes); PR template; milestone 1.0 + #9–#41; release-prep.sh + ship.sh from main, beta/stable channels, DMG out of git; brain issues → GitHub #42–#68, TODOs → #69–#74 · CI green, then protect main, open the PR · CI still red on Xcode 26.6 compile errors (run 5 pending)
2026-09-24 · mac-claude/claude/jev-popularity-comparison-t530yd · owner queue: 1 General Chat rename (7f18a2e), 2 Shift-only hotkeys rejected + test (0c78430), 3 §4 table checked (4dc384a), 4 as-built notes (d7773b4), 6 Global Context key on the ⌘⌘ row (6a59eeb); CI: test host skips launch (d1453d6) · open PR to general-chat-agent when CI green; then 5 (Selection in the Corner) on its own branch · item 5 waits for the PR merge
2026-09-24 · mac-claude/claude/jev-popularity-comparison-t530yd · CI red on PR #76: PluginScriptRunner hung when the host exhausted DispatchQueue.global (osascript/AE waits on CI); reads+wait moved to own threads, deadline bounds the drain; 20× plugin tests + full suite green · owner merges #76 once CI green, then step 2 (inventory check on the app) · —
2026-09-24 · mac-claude/selection-in-corner · owner queue 5: the corner selection card lists the Dock's Selection Scope rows (SelectionActionSource bridge), ↑/↓/↩, ✕ close; tests SelectionScopeActionTests (5d04431) · hand-check each row kind from the corner; then §4b (corner swipes = Dock) · —

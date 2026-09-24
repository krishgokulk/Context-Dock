# MEMORY — cross-session shift log

Append-only. One line per session, newest at the bottom. Never rewrite or delete someone
else's line — several agents write here, and appending is what keeps that safe.

Format: `YYYY-MM-DD · agent/branch · did · next · blocked`

2026-09-24 · claude/jev-popularity-comparison-t530yd · wrote docs/master 00-* plans + DORAX-BLUEPRINT; moved vendored skills to .claude/skills; added scripts/check.sh, .claude/hooks/stop.sh + graphify-guard.sh (not yet wired) · owner wires hooks + cleans .claude/settings.json (see 00-PROJECT-TREE.md §2) · agent may not edit its own permissions/guard hooks
2026-09-24 · claude/jev-popularity-comparison-t530yd · check.sh now tolerates the build.db prune flake (only when it is the sole error and the binary is fresh) — found on the Mac · owner: pull, re-run check.sh, then settings.json · —

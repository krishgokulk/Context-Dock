#!/usr/bin/env bash
# Fails when a skill that lives in BOTH trees (.claude/skills for Claude, .agents/skills for Codex)
# has diverged. Skills present in only one tree are provider-specific and fine.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bad=0
for dir in "$ROOT_DIR"/.claude/skills/*/; do
  name="$(basename "$dir")"
  other="$ROOT_DIR/.agents/skills/$name"
  [ -d "$other" ] || continue
  if ! diff -rq -x Icon -x .DS_Store "$dir" "$other" >/dev/null; then
    echo "skills-parity: '$name' differs between .claude/skills and .agents/skills" >&2
    bad=1
  fi
done
[ "$bad" -eq 0 ] && echo "skills-parity: OK"
exit "$bad"

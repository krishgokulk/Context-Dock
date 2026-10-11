#!/usr/bin/env bash
# Stop hook: no agent turn ends on a broken build.
# Runs scripts/check.sh only when Swift sources are modified and Xcode is present,
# so docs-only turns and cloud (Linux) sessions finish instantly.
# Exit 2 hands the failure back to the agent to fix; any other outcome lets it stop.
set -u

[ "$(jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0   # no loops
command -v xcodebuild >/dev/null 2>&1 || exit 0

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -z "$root" ] && exit 0
[ -z "$(git -C "$root" status --porcelain -- '*.swift' 2>/dev/null | head -1)" ] && exit 0

if ! out="$("$root/scripts/check.sh" 2>&1)"; then
  {
    echo "scripts/check.sh failed — fix the build before finishing."
    echo "(If another session's edit broke it, say so instead of editing their files.)"
    printf '%s\n' "$out" | tail -40
  } >&2
  exit 2
fi
exit 0

#!/usr/bin/env bash
# Build and launch one PR's code without touching the main checkout.
#
#   ./scripts/try-pr.sh 209        # PR #209's latest commit
#   ./scripts/try-pr.sh 209 4f23479 # one exact commit of it
#
# The PR gets its own worktree beside this checkout (../Context-Dock-pr-<n>), with its own
# .build, so the main checkout stays on general-chat-agent and stays your daily app. Only one
# DoraX runs at a time: this quits the running copy and launches the PR's. Go back to the main
# build with ./scripts/main.sh.
set -euo pipefail

PR="${1:?usage: try-pr.sh <pr-number> [commit]}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_DIR="$(git -C "$ROOT_DIR" worktree list --porcelain | awk 'NR==1{print $2}')"
DIR="$(dirname "$MAIN_DIR")/Context-Dock-pr-$PR"

git -C "$MAIN_DIR" fetch --quiet origin "pull/$PR/head:refs/remotes/origin/pr/$PR" --force
TARGET="${2:-origin/pr/$PR}"

if [ -d "$DIR" ]; then
  if [ -n "$(git -C "$DIR" status --porcelain --untracked-files=no)" ]; then
    echo "try-pr: $DIR has local edits; not touching it." >&2
    exit 1
  fi
  git -C "$DIR" checkout --quiet --detach "$TARGET"
else
  git -C "$MAIN_DIR" worktree add --quiet --detach "$DIR" "$TARGET"
fi

# Git-ignored, so a new worktree's first build fails in actool without it.
if [ ! -e "$DIR/Context-Dock/AppIcon.icon" ] && [ -e "$MAIN_DIR/Context-Dock/AppIcon.icon" ]; then
  cp -R "$MAIN_DIR/Context-Dock/AppIcon.icon" "$DIR/Context-Dock/"
fi

echo "try-pr: PR #$PR at $(git -C "$DIR" log --oneline -1) — $DIR"
"$DIR/scripts/dev-run.sh"

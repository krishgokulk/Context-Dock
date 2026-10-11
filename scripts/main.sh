#!/usr/bin/env bash
# Your daily DoraX: the main checkout on the latest general-chat-agent, built and launched.
#
#   ./scripts/main.sh
#
# Fast-forward only. It refuses when the main checkout is on another branch or has edits,
# because both mean someone (or some session) is working in it, and code work belongs in a
# worktree (.claude/worktrees/ for agents, ../Context-Dock-pr-<n> for try-pr.sh).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_DIR="$(git -C "$ROOT_DIR" worktree list --porcelain | awk 'NR==1{print $2}')"
BRANCH="$(git -C "$MAIN_DIR" branch --show-current)"

if [ "$BRANCH" != "general-chat-agent" ]; then
  echo "main: $MAIN_DIR is on '$BRANCH', not general-chat-agent. Switch it back yourself first." >&2
  exit 1
fi
if [ -n "$(git -C "$MAIN_DIR" status --porcelain --untracked-files=no)" ]; then
  echo "main: $MAIN_DIR has uncommitted edits; leaving it alone:" >&2
  git -C "$MAIN_DIR" status --short --untracked-files=no >&2
  exit 1
fi

git -C "$MAIN_DIR" pull --quiet --ff-only origin general-chat-agent
echo "main: $(git -C "$MAIN_DIR" log --oneline -1)"
"$MAIN_DIR/scripts/dev-run.sh"

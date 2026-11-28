#!/usr/bin/env bash
# Show every worktree with its size and age, and remove the ones you no longer need.
#
#   ./scripts/clean-worktrees.sh                # list only
#   ./scripts/clean-worktrees.sh --pr           # also remove ../Context-Dock-pr-* / check* test worktrees
#   ./scripts/clean-worktrees.sh --merged       # also remove worktrees whose branch is merged into general-chat-agent
#   ./scripts/clean-worktrees.sh --prune-builds # reclaim redundant .build/ dirs in non-main worktrees (safe even with edits)
#
# A worktree with uncommitted edits is never removed. Because all worktrees now share
# <main-repo>/.build/XcodeDerivedData, stale per-worktree .build/ folders are safe to prune.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_DIR="$(git -C "$ROOT_DIR" worktree list --porcelain | awk 'NR==1{print $2}')"
REMOVE_PR=0
REMOVE_MERGED=0
PRUNE_BUILDS=0
for arg in "$@"; do
  case "$arg" in
    --pr) REMOVE_PR=1 ;;
    --merged) REMOVE_MERGED=1 ;;
    --prune-builds) PRUNE_BUILDS=1 ;;
  esac
done

git -C "$MAIN_DIR" worktree prune
printf '%-8s %-12s %s\n' "SIZE" "LAST COMMIT" "WORKTREE (branch)"
git -C "$MAIN_DIR" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}' | while read -r WT; do
  [ -d "$WT" ] || continue
  if [ "$PRUNE_BUILDS" = 1 ] && [ "$WT" != "$MAIN_DIR" ] && [ -d "$WT/.build" ]; then
    BSIZE="$(du -sh "$WT/.build" 2>/dev/null | cut -f1)"
    rm -rf "$WT/.build"
    echo "pruned   $BSIZE        $WT/.build"
  fi
  SIZE="$(du -sh "$WT" 2>/dev/null | cut -f1)"
  WHEN="$(git -C "$WT" log -1 --format=%cs 2>/dev/null || echo '?')"
  BR="$(git -C "$WT" branch --show-current 2>/dev/null)"
  printf '%-8s %-12s %s (%s)\n' "$SIZE" "$WHEN" "$WT" "${BR:-detached}"

  case "$(basename "$WT")" in
    Context-Dock-pr-*|Context-Dock-check*|Context-Dock-u8-*)
      if [ "$REMOVE_PR" = 1 ]; then
        if [ -n "$(git -C "$WT" status --porcelain --untracked-files=no)" ]; then
          echo "         kept: has uncommitted edits"
        else
          git -C "$MAIN_DIR" worktree remove --force "$WT" && echo "         removed"
        fi
      fi
      ;;
  esac

  if [ "$REMOVE_MERGED" = 1 ] && [ -n "$BR" ] && [ "$BR" != "general-chat-agent" ]; then
    if git -C "$MAIN_DIR" merge-base --is-ancestor "$BR" general-chat-agent 2>/dev/null; then
      if [ -n "$(git -C "$WT" status --porcelain --untracked-files=no)" ]; then
        echo "         kept: merged but has uncommitted edits"
      else
        git -C "$MAIN_DIR" worktree remove --force "$WT" && git -C "$MAIN_DIR" branch -d "$BR" 2>/dev/null && echo "         removed (merged)"
      fi
    fi
  fi
done

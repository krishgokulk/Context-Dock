#!/usr/bin/env bash
# Show every worktree with its size and age, and remove the ones you no longer need.
#
#   ./scripts/clean-worktrees.sh          # list only
#   ./scripts/clean-worktrees.sh --pr     # also remove ../Context-Dock-pr-* test worktrees
#
# A worktree with uncommitted edits is never removed. Agent worktrees in .claude/worktrees/
# are listed but left to their sessions. Each worktree carries its own .build (several GB),
# which is where the disk goes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_DIR="$(git -C "$ROOT_DIR" worktree list --porcelain | awk 'NR==1{print $2}')"
REMOVE_PR=0
[ "${1:-}" = "--pr" ] && REMOVE_PR=1

git -C "$MAIN_DIR" worktree prune
printf '%-8s %-12s %s\n' "SIZE" "LAST COMMIT" "WORKTREE (branch)"
git -C "$MAIN_DIR" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}' | while read -r WT; do
  [ -d "$WT" ] || continue
  SIZE="$(du -sh "$WT" 2>/dev/null | cut -f1)"
  WHEN="$(git -C "$WT" log -1 --format=%cs 2>/dev/null || echo '?')"
  BR="$(git -C "$WT" branch --show-current 2>/dev/null)"
  printf '%-8s %-12s %s (%s)\n' "$SIZE" "$WHEN" "$WT" "${BR:-detached}"

  case "$(basename "$WT")" in
    Context-Dock-pr-*)
      if [ "$REMOVE_PR" = 1 ]; then
        if [ -n "$(git -C "$WT" status --porcelain --untracked-files=no)" ]; then
          echo "         kept: has uncommitted edits"
        else
          git -C "$MAIN_DIR" worktree remove --force "$WT" && echo "         removed"
        fi
      fi
      ;;
  esac
done

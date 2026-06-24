#!/bin/bash
# sync-agents.sh
# Keeps CLAUDE.md and AGENTS.md in sync.
# Run this after editing either file.
#
# Usage:
#   ./sync-agents.sh claude   -> copies CLAUDE.md content into AGENTS.md (keeping its header)
#   ./sync-agents.sh agents   -> copies AGENTS.md content into CLAUDE.md (keeping its header)
#   ./sync-agents.sh          -> shows diff between the two files

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
CLAUDE="$PROJECT_ROOT/CLAUDE.md"
AGENTS="$PROJECT_ROOT/AGENTS.md"

case "$1" in
  claude)
    echo "Syncing AGENTS.md from CLAUDE.md..."
    cp "$CLAUDE" "$AGENTS"
    # Replace 'Claude' references with 'Codex' in the header line only
    sed -i '' '1s/Claude Code/Codex/' "$AGENTS"
    sed -i '' 's|Codex.ai/code|Codex.ai/code|' "$AGENTS"
    echo "Done. AGENTS.md updated."
    ;;
  agents)
    echo "Syncing CLAUDE.md from AGENTS.md..."
    cp "$AGENTS" "$CLAUDE"
    echo "Done. CLAUDE.md updated."
    ;;
  *)
    echo "=== Diff: CLAUDE.md vs AGENTS.md ==="
    diff --unified=2 "$CLAUDE" "$AGENTS" || true
    echo ""
    echo "Run: ./sync-agents.sh claude   (to push CLAUDE.md -> AGENTS.md)"
    echo "Run: ./sync-agents.sh agents   (to push AGENTS.md -> CLAUDE.md)"
    ;;
esac

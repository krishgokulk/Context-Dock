#!/bin/bash
# generate-context.sh
# Generates CONTEXT.md — paste it into ChatGPT instead of uploading a zip.
# Usage:  ./generate-context.sh
# Copy:   pbcopy < CONTEXT.md

REPO="$HOME/Desktop/Context-Dock"
OUT="$REPO/CONTEXT.md"
DATE=$(date '+%Y-%m-%d %H:%M')

echo "Generating CONTEXT.md..."

{
echo "# Context-Dock — AI Context Snapshot"
echo "Generated: $DATE"
echo ""
echo "## App overview"
echo "macOS 26 launcher and dock-replacement app."
echo "Bundle: com.krishgokul.ContextDock"
echo "Swift 5, SwiftUI, macOS 26.1 minimum, 265+ Swift files."
echo "Targets: Context-Dock (main), Context-DockExtension (Safari), SwiftTerm (terminal)."
echo ""
echo "## DoraX architecture rules — NEVER violate"
echo "- Global Context, Chat Mode, Context Dock, Selection Sheet, Media Dock are separate surfaces."
echo "- Each surface has ONE job. Never merge layers."
echo "- Unified Dock Shell: one container, multiple modes. No separate floating windows per mode."
echo "- Architecture truth lives in docs/architecture/"
echo ""
echo "## Folder rules — new files must go here"
echo "App/           entry point, AppSettings, AppState, AppRouter, launch helpers"
echo "AI/Providers/  AI adapters (Anthropic, OpenAI, Gemini, Ollama, OpenAI-compatible)"
echo "Accessibility/ AX observer, AXEventBus, context snapshots"
echo "Automation/    cross-app routing, menu intent, app-specific macros"
echo "Search/        LauncherView, surfaces, coordinators, dock rows, pill system"
echo "Services/      shared infrastructure (context, media, file, extensions)"
echo "UI/Settings/   settings pages only"
echo "UI/            reusable components (overlays, toasts, panels)"
echo ""
echo "## All Swift files by folder"
SRC="$REPO/Context-Dock"
for dir in App AI Accessibility Automation Search Services UI; do
  COUNT=$(find "$SRC/$dir" -name '*.swift' 2>/dev/null | wc -l | tr -d ' ')
  echo ""
  echo "### $dir/ ($COUNT files)"
  find "$SRC/$dir" -name '*.swift' 2>/dev/null \
    | sed "s|$SRC/||" | sort
done
echo ""
echo "## Recent commits (last 10)"
git -C "$REPO" log -10 --pretty=format:"- %h %s (%ar)" --no-merges 2>/dev/null
echo ""
echo ""
echo "## CHANGES.md (last 30 lines)"
tail -30 "$REPO/CHANGES.md" 2>/dev/null || echo "(no CHANGES.md yet)"
} > "$OUT"

LINES=$(wc -l < "$OUT" | tr -d ' ')
SIZE=$(wc -c < "$OUT" | tr -d ' ')
echo "Done: $LINES lines, $SIZE bytes -> $OUT"
echo ""
echo "Copy to clipboard:  pbcopy < $OUT"
echo "Open file:          open $OUT"

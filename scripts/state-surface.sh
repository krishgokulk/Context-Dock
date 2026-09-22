#!/usr/bin/env bash
# state-surface.sh — what a LauncherView view property actually touches.
#
# Before extracting a `some View` property into a type of its own, you need two lists: the
# stored properties it reads, and the methods it calls. Those become the new view's inputs.
# Guessing them is how an extraction turns into an afternoon of compiler errors.
#
#   ./scripts/state-surface.sh appPanelView Context-Dock/Search/LauncherView+LivePanel.swift
#
# Written for docs/superpowers/plans/2026-09-22-launcherview-body-decomposition.md (#25).
set -euo pipefail

PROP="${1:?usage: state-surface.sh <propertyName> <file>}"
FILE="${2:?usage: state-surface.sh <propertyName> <file>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The property body, from its declaration to the closing brace at the same indentation.
awk -v prop="$PROP" '
  $0 ~ "^    (private )?(@ViewBuilder )?var " prop ": some View \\{" { inside = 1 }
  inside { print }
  inside && /^    \}$/ { exit }
' "$FILE" > "$TMP/prop.txt"

if [ ! -s "$TMP/prop.txt" ]; then
  echo "did not find '$PROP' in $FILE — check the name and that it returns 'some View'" >&2
  exit 1
fi

echo "== $PROP in $FILE ($(wc -l < "$TMP/prop.txt" | tr -d ' ') lines) =="

grep -ohE "\b[a-zA-Z_][a-zA-Z0-9_]*\b" "$TMP/prop.txt" | sort -u > "$TMP/ids.txt"

grep -ohE "@(State|StateObject|ObservedObject|Binding|FocusState|AppStorage|EnvironmentObject|Environment)[^v]*var [a-zA-Z0-9_]+" \
  Context-Dock/Search/LauncherView.swift | awk '{print $NF}' | sort -u > "$TMP/states.txt"

echo
echo "-- stored properties it reads (each becomes a binding or a value) --"
comm -12 "$TMP/ids.txt" "$TMP/states.txt" || true

grep -ohE "^    (private )?func [a-zA-Z0-9_]+" Context-Dock/Search/LauncherView*.swift \
  | awk '{print $NF}' | sort -u > "$TMP/methods.txt"
grep -ohE "\b[a-z][a-zA-Z0-9]*\(" "$TMP/prop.txt" | tr -d '(' | sort -u > "$TMP/calls.txt"

echo
echo "-- LauncherView methods it calls (each becomes a closure parameter) --"
comm -12 "$TMP/calls.txt" "$TMP/methods.txt" || true

echo
echo "Methods stay on LauncherView and are passed in; do not move their bodies."

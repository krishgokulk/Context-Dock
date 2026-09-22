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
# Matches a property or a function: most of LauncherView's view members are functions,
# and the leaf set is mostly functions, so a var-only pattern silently finds nothing.
awk -v prop="$PROP" '
  $0 ~ "^    (private )?(@ViewBuilder )?var " prop ": some View \\{" { inside = 1 }
  $0 ~ "^    (private )?(@ViewBuilder )?func " prop "\\(" { inside = 1 }
  inside { print }
  inside && /^    \}$/ { exit }
' "$FILE" > "$TMP/prop.txt"

if [ ! -s "$TMP/prop.txt" ]; then
  echo "did not find '$PROP' in $FILE — check the name, and that it is a var returning 'some View' or a func" >&2
  exit 1
fi

echo "== $PROP in $FILE ($(wc -l < "$TMP/prop.txt" | tr -d ' ') lines) =="

grep -ohE "\b[a-zA-Z_][a-zA-Z0-9_]*\b" "$TMP/prop.txt" | sort -u > "$TMP/ids.txt"

grep -ohE "@(State|StateObject|ObservedObject|Binding|FocusState|AppStorage|EnvironmentObject|Environment)[^v]*var [a-zA-Z0-9_]+" \
  Context-Dock/Search/LauncherView.swift | awk '{print $NF}' | sort -u > "$TMP/states.txt"

echo
echo "-- stored properties it reads (each becomes a binding or a value) --"
comm -12 "$TMP/ids.txt" "$TMP/states.txt" || true

# Computed properties are the trap. Swift extensions cannot hold stored properties, so the
# @State list above is complete by construction — but computed vars live in any of the
# LauncherView+*.swift files, and they read state of their own. Missing them is how an
# extraction gets halfway done before the compiler starts complaining.
grep -ohE "^    (private )?var [a-zA-Z0-9_]+: [^=]+\{" Context-Dock/Search/LauncherView*.swift \
  | sed -E 's/^ *(private )?var ([a-zA-Z0-9_]+):.*/\2/' | sort -u > "$TMP/computed.txt"
comm -13 "$TMP/states.txt" "$TMP/computed.txt" > "$TMP/computed-only.txt"

echo
echo "-- computed properties on LauncherView it reads --"
comm -12 "$TMP/ids.txt" "$TMP/computed-only.txt" || true

grep -ohE "^    (private )?func [a-zA-Z0-9_]+" Context-Dock/Search/LauncherView*.swift \
  | awk '{print $NF}' | sort -u > "$TMP/methods.txt"
grep -ohE "\b[a-z][a-zA-Z0-9]*\(" "$TMP/prop.txt" | tr -d '(' | sort -u > "$TMP/calls.txt"

echo
echo "-- LauncherView methods it calls (each becomes a closure parameter) --"
comm -12 "$TMP/calls.txt" "$TMP/methods.txt" || true

echo
echo
echo "Methods and computed properties stay on LauncherView and are passed in as values or"
echo "closures; do not move their bodies. A computed property that is written as well as"
echo "read (a get/set bridge) needs a Binding, not a value."

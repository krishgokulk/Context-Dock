#!/usr/bin/env bash
# Portable wrapper for graphify's search/read guard. Finds graphify on PATH or in
# ~/.local/bin, and does nothing where it is not installed (cloud sessions, other Macs).
g="$(command -v graphify 2>/dev/null || true)"
[ -z "$g" ] && [ -x "$HOME/.local/bin/graphify" ] && g="$HOME/.local/bin/graphify"
[ -z "$g" ] && exit 0
exec "$g" hook-guard "$1"

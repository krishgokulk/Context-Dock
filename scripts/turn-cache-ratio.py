#!/usr/bin/env python3
"""Prompt-cache read ratio over the last N turn records in the turn log.

The turn log is off by default. Switch it on, use the app, then run this:

    defaults write com.krishgokul.ContextDock doraxTurnLogEnabled -bool YES
    python3 scripts/turn-cache-ratio.py            # last 50 turns
    python3 scripts/turn-cache-ratio.py --last 20 path/to/turns.log

The ratio is cache-read input tokens over all input tokens, across the turns whose
provider reported input. Records come from Services/TurnRecorder.swift; the same
computation is TurnTraceReport.cacheReadRatio, covered by TurnRecorderTests.
"""

import argparse
import json
import os
import sys

PREFIX = "turn.trace "
DEFAULT_LOG = os.path.expanduser(
    "~/Library/Application Support/Context-Dock/turns.log")


def traces(lines):
    for line in lines:
        index = line.find(PREFIX)
        if index < 0:
            continue
        try:
            yield json.loads(line[index + len(PREFIX):])
        except json.JSONDecodeError:
            continue  # a record cut off when the log was started again


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("log", nargs="?", default=DEFAULT_LOG)
    parser.add_argument("--last", type=int, default=50)
    args = parser.parse_args()

    try:
        with open(args.log, encoding="utf-8", errors="replace") as handle:
            records = list(traces(handle))
    except FileNotFoundError:
        sys.exit(f"No turn log at {args.log}. Is doraxTurnLogEnabled on?")

    reporting = [r for r in records if "gen_ai.usage.input_tokens" in r][-args.last:]
    if not reporting:
        sys.exit(f"{len(records)} turn records, none with input token counts.")

    total = sum(r["gen_ai.usage.input_tokens"] for r in reporting)
    cached = sum(r.get("gen_ai.usage.cache_read.input_tokens", 0) for r in reporting)
    ratio = cached / total if total else 0.0
    by_provider = {}
    for r in reporting:
        key = f'{r.get("gen_ai.provider.name", "?")} {r.get("gen_ai.request.model", "")}'.strip()
        by_provider[key] = by_provider.get(key, 0) + 1

    print(f"turns: {len(reporting)} of {len(records)} records (last {args.last} with input counts)")
    print(f"input tokens: {total}  cache-read: {cached}  ratio: {ratio:.1%}")
    for key, count in sorted(by_provider.items(), key=lambda item: -item[1]):
        print(f"  {count:3d}  {key}")


if __name__ == "__main__":
    main()

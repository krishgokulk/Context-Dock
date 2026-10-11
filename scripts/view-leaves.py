#!/usr/bin/env python3
"""view-leaves.py — which LauncherView view members are safe to extract next.

For #25. A view member is only worth extracting once it calls no other view member:
a struct that takes opaque children as @ViewBuilder parameters becomes generic over
their types, substitution recurses back into them, and no boundary is created.

Signatures wrap. `func dockCapsuleSelectionBackground(` puts its `-> some View` three
lines down, and a single-line regex silently treats it as not-a-view — which is how
groupedMenuPillRow was first mistaken for a leaf. This joins continuation lines.

    ./scripts/view-leaves.py            # the leaf list, largest first
    ./scripts/view-leaves.py --all      # every view member and what it uses
"""
import glob, io, re, sys

DECL = re.compile(r"^    (?:private |internal |public )?(?:@ViewBuilder\s*)?(var|func)\s+([A-Za-z0-9_]+)\s*[:(]")
WORD = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")


def members():
    found = {}
    for path in sorted(glob.glob("Context-Dock/Search/LauncherView*.swift")):
        lines = io.open(path, encoding="utf-8").read().split("\n")
        for i, line in enumerate(lines):
            m = DECL.match(line)
            if not m:
                continue
            # No arbitrary cap. appPillButton's parameter list runs fourteen lines before
            # its "-> some View", and a twelve-line limit silently classified it as not a
            # view — which then made pinnedAndRecentAppsRow look like a leaf. Scan to the
            # brace that actually opens the body.
            sig, j = line, i
            while "{" not in sig and j + 1 < len(lines):
                j += 1
                sig += " " + lines[j].strip()
            if "some View" not in sig:
                continue
            depth = 0
            for k in range(j, len(lines)):
                depth += lines[k].count("{") - lines[k].count("}")
                if depth == 0 and k > j:
                    found[m.group(2)] = (path, i + 1, "\n".join(lines[i:k + 1]))
                    break
    return found


def reachable_from_body(found, uses_of):
    """Members LauncherView.body can actually reach.

    Only these contribute to body's opaque type. Extracting a member nothing reaches
    changes nothing — measured: appPillButton and globalInlineScopeChip together are 309
    lines and moved the count by 8, where 341 reachable lines had moved it by 768.
    """
    seen, stack = set(), ["body"]
    while stack:
        name = stack.pop()
        if name in seen or name not in found:
            continue
        seen.add(name)
        stack.extend(uses_of[name])
    return seen


def main():
    found = members()
    names = set(found)
    uses_of = {}
    for name, (path, line, body) in found.items():
        uses_of[name] = (set(WORD.findall(body)) & names) - {name}

    live = reachable_from_body(found, uses_of)
    rows = []
    for name, (path, line, body) in found.items():
        rows.append((len(body.split("\n")), name, path.split("/")[-1], line,
                     sorted(uses_of[name]), name in live))

    show_all = "--all" in sys.argv
    rows.sort(reverse=True)
    leaves = [r for r in rows if not r[4]]
    live_leaves = [r for r in leaves if r[5]]

    print(f"view members {len(found)}   reachable from body {len(live)}")
    print(f"true leaves {len(leaves)}   of those reachable {len(live_leaves)}   "
          f"reachable leaf lines {sum(r[0] for r in live_leaves)}")
    print()
    print("-- extract these: leaves body can actually reach --")
    for n, name, f, line, uses, _ in live_leaves:
        print(f"{n:5d}  {name}  ({f}:{line})")
    if show_all:
        print()
        print("-- leaves nothing reaches from body (extracting these changes nothing) --")
        for n, name, f, line, uses, islive in leaves:
            if not islive:
                print(f"{n:5d}  {name}  ({f}:{line})")


if __name__ == "__main__":
    main()

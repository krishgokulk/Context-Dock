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


def main():
    found = members()
    names = set(found)
    rows = []
    for name, (path, line, body) in found.items():
        uses = (set(WORD.findall(body)) & names) - {name}
        rows.append((len(body.split("\n")), name, path.split("/")[-1], line, sorted(uses)))

    show_all = "--all" in sys.argv
    rows.sort(reverse=True)
    leaves = [r for r in rows if not r[4]]

    print(f"view members {len(found)}   true leaves {len(leaves)}   leaf lines {sum(r[0] for r in leaves)}")
    print()
    for n, name, f, line, uses in (rows if show_all else leaves):
        if show_all and uses:
            print(f"{n:5d}  {name}  ({f}:{line})  uses: {', '.join(uses[:4])}{'…' if len(uses) > 4 else ''}")
        else:
            print(f"{n:5d}  {name}  ({f}:{line})")


if __name__ == "__main__":
    main()

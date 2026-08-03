import json, os, re, sys, time, urllib.request

CACHE = os.path.expanduser("~/Library/Caches/context-dock-fx.json")
DEFAULT_TARGETS = ["USD", "EUR", "GBP", "INR", "JPY"]
SYMBOL = {"USD": "$", "EUR": "€", "GBP": "£", "INR": "₹",
          "JPY": "¥", "AUD": "A$", "CAD": "C$", "CHF": "CHF", "CNY": "¥"}

def row(**kw):
    print(json.dumps(kw))

def hint(msg, sub):
    row(id="hint", title=msg, subtitle=sub, icon="questionmark.circle")

def resting_card(table):
    """Entering the scope shows the same card shape a real conversion uses, so the
    panel does not change geometry the moment the user starts typing. Uses a live
    rate for 1 USD, so the resting state is informative rather than a placeholder."""
    base, target = "USD", "INR"
    if base not in table or target not in table:
        hint("Type an amount and currency", "e.g. 100 usd inr, 500 inr, 20 gbp to jpy")
        return
    row(id="resting", layout="compare",
        left=money(1, base), right=money(table[target] / table[base], target),
        title="e.g. 100 usd inr", badge=target, centerIcon="arrow.right")

def rates():
    # One network call an hour: a converter re-runs on every keystroke, and the
    # ECB-derived feed only moves daily.
    try:
        if time.time() - os.path.getmtime(CACHE) < 3600:
            with open(CACHE) as f:
                return json.load(f)["rates"]
    except Exception:
        pass
    with urllib.request.urlopen("https://open.er-api.com/v6/latest/USD", timeout=6) as r:
        data = json.load(r)
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        with open(CACHE, "w") as f:
            json.dump(data, f)
    except Exception:
        pass
    return data["rates"]

def money(v, code):
    sym = SYMBOL.get(code, "")
    if v >= 100:
        s = format(v, ",.2f")
    elif v >= 1:
        s = format(v, ",.3f").rstrip("0").rstrip(".")
    else:
        s = format(v, ",.4f").rstrip("0").rstrip(".")
    return f"{sym}{s}" if sym else f"{s} {code}"

def main():
    q = (os.environ.get("CD_QUERY") or "").strip()
    if not q:
        try:
            resting_card(rates())
        except Exception:
            hint("Type an amount and currency", "e.g. 100 usd inr, 500 inr, 20 gbp to jpy")
        return

    # "100usd inr", "100 usd to inr", "500 inr", "100 usd" all parse the same:
    # a number, then any currency codes that follow, in order.
    m = re.match(r"\s*([0-9][0-9,]*\.?[0-9]*)\s*(.*)$", q, re.I)
    if not m:
        hint("Start with an amount", "e.g. 100 usd inr")
        return
    amount = float(m.group(1).replace(",", ""))
    codes = [c.upper() for c in re.findall(r"[A-Za-z]{3}", m.group(2))
             if c.lower() != "to"]

    try:
        table = rates()
    except Exception as e:
        hint("Rates unavailable", str(e)[:60])
        return

    base = codes[0] if codes and codes[0] in table else "USD"
    targets = [c for c in codes[1:] if c in table and c != base]
    if not targets:
        targets = [c for c in DEFAULT_TARGETS if c != base]

    unknown = [c for c in codes if c not in table]
    if unknown:
        hint("Unknown currency: " + ", ".join(unknown), "Use ISO codes like usd, eur, inr")

    for code in targets:
        converted = amount * table[code] / table[base]
        row(id=code,
            layout="compare",
            left=money(amount, base),
            right=money(converted, code),
            title=base,
            badge=code,
            centerIcon="arrow.right")

main()

#!/usr/bin/env python3
"""Context Dock — Currency Converter list extension.

Rows mode (no args): reads $CD_QUERY, prints compare cards.
Action mode (--row): Return on a row — picks a currency, or copies a result.
"""
import json, os, re, sys, time, urllib.request

SUPPORT = os.path.expanduser("~/Library/Application Support/Context-Dock")
CACHE = os.path.join(SUPPORT, "fx-rates.json")
PREF = os.path.join(SUPPORT, "currency-target.json")
DEFAULT_TARGET = "INR"

SYMBOL = {"USD": "$", "EUR": "€", "GBP": "£", "INR": "₹", "JPY": "¥",
          "AUD": "A$", "CAD": "C$", "NZD": "NZ$", "CNY": "¥", "KRW": "₩",
          "BRL": "R$", "RUB": "₽", "TRY": "₺", "ILS": "₪", "PHP": "₱",
          "THB": "฿", "VND": "₫", "NGN": "₦", "PLN": "zł", "CHF": "CHF"}

NAMES = {
 "USD":"US Dollar","EUR":"Euro","GBP":"Pound Sterling","INR":"Indian Rupee",
 "JPY":"Japanese Yen","AUD":"Australian Dollar","CAD":"Canadian Dollar",
 "CHF":"Swiss Franc","CNY":"Chinese Yuan","HKD":"Hong Kong Dollar",
 "NZD":"New Zealand Dollar","SEK":"Swedish Krona","NOK":"Norwegian Krone",
 "DKK":"Danish Krone","SGD":"Singapore Dollar","KRW":"South Korean Won",
 "ZAR":"South African Rand","BRL":"Brazilian Real","MXN":"Mexican Peso",
 "RUB":"Russian Ruble","TRY":"Turkish Lira","AED":"UAE Dirham",
 "SAR":"Saudi Riyal","QAR":"Qatari Riyal","KWD":"Kuwaiti Dinar",
 "BHD":"Bahraini Dinar","OMR":"Omani Rial","PKR":"Pakistani Rupee",
 "BDT":"Bangladeshi Taka","LKR":"Sri Lankan Rupee","NPR":"Nepalese Rupee",
 "IDR":"Indonesian Rupiah","MYR":"Malaysian Ringgit","THB":"Thai Baht",
 "VND":"Vietnamese Dong","PHP":"Philippine Peso","TWD":"Taiwan Dollar",
 "PLN":"Polish Zloty","CZK":"Czech Koruna","HUF":"Hungarian Forint",
 "RON":"Romanian Leu","ILS":"Israeli New Shekel","EGP":"Egyptian Pound",
 "NGN":"Nigerian Naira","KES":"Kenyan Shilling","GHS":"Ghanaian Cedi",
 "ARS":"Argentine Peso","CLP":"Chilean Peso","COP":"Colombian Peso",
 "PEN":"Peruvian Sol","UAH":"Ukrainian Hryvnia","ISK":"Icelandic Krona",
}

def row(**kw):
    print(json.dumps(kw))

def name_of(code):
    return NAMES.get(code, code)

def load_target():
    try:
        v = json.load(open(PREF))
        return v.get("target") or DEFAULT_TARGET
    except Exception:
        return DEFAULT_TARGET

def save_target(code):
    os.makedirs(SUPPORT, exist_ok=True)
    json.dump({"target": code}, open(PREF, "w"))

def rates():
    # One call an hour: this re-runs on every keystroke and the feed moves daily.
    try:
        if time.time() - os.path.getmtime(CACHE) < 3600:
            return json.load(open(CACHE))["rates"]
    except Exception:
        pass
    with urllib.request.urlopen("https://open.er-api.com/v6/latest/USD", timeout=6) as r:
        data = json.load(r)
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        json.dump(data, open(CACHE, "w"))
    except Exception:
        pass
    return data["rates"]

def money(v, code):
    sym = SYMBOL.get(code, "")
    if v >= 100:      s = format(v, ",.2f")
    elif v >= 1:      s = format(v, ",.3f").rstrip("0").rstrip(".")
    else:             s = format(v, ",.4f").rstrip("0").rstrip(".")
    return f"{sym}{s}" if sym else f"{s} {code}"

def convert_row(amount, base, code, table):
    """One card. A wall of currencies is a picker's job — the panel answers the
    question actually asked and stays one row tall."""
    row(id=f"copy:{money(amount * table[code] / table[base], code)}",
        layout="compare",
        left=money(amount, base), right=money(amount * table[code] / table[base], code),
        title=name_of(base), badge=code, centerIcon="arrow.right")

def picker_rows(term, table, current, amount, base):
    """The currency list, filtered as the user types. Return makes that currency the
    one the panel converts to, and it sticks."""
    term = term.lower()
    hits = [c for c in sorted(table)
            if term in c.lower() or term in name_of(c).lower()]
    if not hits:
        row(id="none", title=f"No currency matching “{term}”",
            subtitle="Try a code (jpy) or a name (yen)", icon="magnifyingglass")
        return
    for code in hits[:12]:
        on = code == current
        preview = money(amount * table[code] / table[base], code) if code in table else ""
        row(id=f"pick:{code}",
            title=f"{name_of(code)}",
            subtitle=f"{code} · {preview}",
            badge="current" if on else None,
            icon="checkmark.circle.fill" if on else "circle")

def do_action(row_id, row_title):
    if row_id.startswith("pick:"):
        save_target(row_id[5:])
        return
    value = row_id[5:] if row_id.startswith("copy:") else row_title
    # Pipe the bytes straight to pbcopy: shelling out through json.dumps escaped
    # the currency symbol and pasted "\u20b9" instead of the rupee sign.
    import subprocess
    subprocess.run(["pbcopy"], input=value.encode("utf-8"))

def main():
    if "--row" in sys.argv:
        i = sys.argv.index("--row")
        rid = sys.argv[i + 1] if len(sys.argv) > i + 1 else ""
        j = sys.argv.index("--title") if "--title" in sys.argv else -1
        title = sys.argv[j + 1] if j >= 0 and len(sys.argv) > j + 1 else ""
        do_action(rid, title)
        return

    q = (os.environ.get("CD_QUERY") or "").strip()
    try:
        table = rates()
    except Exception as e:
        row(id="err", title="Rates unavailable", subtitle=str(e)[:70],
            icon="exclamationmark.triangle")
        return
    target = load_target()
    if target not in table:
        target = DEFAULT_TARGET

    # Resting state uses the same card a real conversion does, so entering the
    # scope and typing never change the panel's shape.
    if not q:
        convert_row(1, "USD", target, table)
        return

    m = re.match(r"\s*([0-9][0-9,]*\.?[0-9]*)\s*(.*)$", q)
    if not m:
        # No amount yet — treat the whole query as a currency search.
        picker_rows(q, table, load_target(), 1, "USD")
        return

    amount = float(m.group(1).replace(",", ""))
    rest = m.group(2).strip()
    tokens = [t for t in re.split(r"[\s,]+", rest) if t and t.lower() != "to"]
    codes = [t.upper() for t in tokens if len(t) == 3 and t.upper() in table]
    unknown = [t for t in tokens if not (len(t) == 3 and t.upper() in table)]

    base = codes[0] if codes else "USD"
    targets = [c for c in codes[1:] if c != base]

    # A word that isn't a code means the user is hunting for a currency.
    if unknown:
        picker_rows(" ".join(unknown), table, target, amount, base)
        return

    # An explicit target in the query also becomes the remembered one, so the next
    # bare amount answers in the currency the user last cared about.
    if targets:
        save_target(targets[0])
        target = targets[0]
    if target == base:
        target = "USD" if base != "USD" else "EUR"
    convert_row(amount, base, target, table)

main()

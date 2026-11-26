#!/usr/bin/env python3
import json
import os
import sys
import time
import urllib.request

CACHE_PATH = "/tmp/dorax-fx-rates-v3.json"
FALLBACK_USD = {
    "USD": 1.0, "EUR": 0.92, "GBP": 0.79, "INR": 84.4, "JPY": 154.0,
    "CAD": 1.40, "AUD": 1.54, "CHF": 0.88, "SGD": 1.34, "AED": 3.6725,
    "CNY": 7.24, "KRW": 1398.0, "SAR": 3.75, "NZD": 1.70
}
CURRENCIES = [
    ("USD", "US Dollar", "Major"),
    ("EUR", "Euro", "Major"),
    ("GBP", "British Pound", "Major"),
    ("INR", "Indian Rupee", "Asia & Gulf"),
    ("JPY", "Japanese Yen", "Asia & Gulf"),
    ("CAD", "Canadian Dollar", "Major"),
    ("AUD", "Australian Dollar", "Major"),
    ("CHF", "Swiss Franc", "Major"),
    ("SGD", "Singapore Dollar", "Asia & Gulf"),
    ("AED", "UAE Dirham", "Asia & Gulf"),
]


def load_usd_rates():
    now = time.time()
    if os.path.isfile(CACHE_PATH):
        try:
            cached = json.load(open(CACHE_PATH))
            if now - cached.get("ts", 0) < 21600 and cached.get("rates"):
                return cached["rates"], "Live Cache"
        except Exception:
            pass
    try:
        req = urllib.request.Request("https://open.er-api.com/v6/latest/USD", headers={"User-Agent": "Context-Dock/1.0"})
        with urllib.request.urlopen(req, timeout=4.5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            rates = data.get("rates") or {}
            if rates:
                json.dump({"ts": now, "rates": rates}, open(CACHE_PATH, "w"))
                return rates, "Live FX"
    except Exception:
        pass
    return FALLBACK_USD, "Offline Ref"


def main():
    try:
        ctx = json.loads(sys.stdin.read().strip() or "{}")
    except Exception:
        ctx = {}
    form = ctx.get("formValues") or {}
    amt_raw = (form.get("amount") or "100").strip().replace(",", "")
    try:
        amount = float(amt_raw)
    except ValueError:
        amount = 100.0
    from_cur = (form.get("from") or "USD").strip().upper()
    to_cur = (form.get("to") or "INR").strip().upper()

    rates, source = load_usd_rates()
    r_from = float(rates.get(from_cur, 1.0))
    r_to = float(rates.get(to_cur, 1.0))
    usd_val = amount / r_from if r_from else amount
    converted = usd_val * r_to

    items = []
    for code, label, cat in CURRENCIES:
        val = usd_val * float(rates.get(code, 1.0))
        fmt_val = f"{val:,.2f}" if val >= 1 else f"{val:.4f}"
        is_target = code == to_cur
        items.append({
            "id": code,
            "title": f"{fmt_val} {code}",
            "subtitle": label,
            "icon": "dollarsign.circle.fill",
            "category": cat,
            "accessories": [
                {"kind": "tag", "text": "Target" if is_target else cat, "color": "#10B981" if is_target else "#64748B"}
            ],
            "actions": [
                {"id": "copy", "title": f"Copy {fmt_val} {code}", "icon": "doc.on.doc", "shortcut": "↵", "kind": "copy", "value": fmt_val}
            ]
        })

    # Move target currency first
    items.sort(key=lambda x: (x["id"] != to_cur,))
    target_str = f"{converted:,.2f}" if converted >= 1 else f"{converted:.4f}"
    print(json.dumps({
        "items": items,
        "detail": {
            "markdown": f"### {amount:,.2f} {from_cur} = {target_str} {to_cur}\n\n**Unit Rate:** 1 {from_cur} = {(r_to / r_from if r_from else 1.0):.4f} {to_cur}\n\n**Source:** {source}",
            "metadata": [
                {"label": "Result", "value": f"{target_str} {to_cur}", "color": "#10B981"},
                {"label": "Source", "value": source},
            ]
        }
    }))


if __name__ == "__main__":
    main()

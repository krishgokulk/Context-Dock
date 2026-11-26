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
    "SAR": 3.75, "MYR": 4.46, "THB": 34.5, "NZD": 1.70
}
META = [
    ("EUR", "Euro", "Major", "€"),
    ("GBP", "British Pound", "Major", "£"),
    ("INR", "Indian Rupee", "Asia & Gulf", "₹"),
    ("JPY", "Japanese Yen", "Asia & Gulf", "¥"),
    ("CAD", "Canadian Dollar", "Major", "C$"),
    ("AUD", "Australian Dollar", "Major", "A$"),
    ("CHF", "Swiss Franc", "Major", "CHF"),
    ("SGD", "Singapore Dollar", "Asia & Gulf", "S$"),
    ("AED", "UAE Dirham", "Asia & Gulf", "د.إ"),
    ("SAR", "Saudi Riyal", "Asia & Gulf", "﷼"),
    ("MYR", "Malaysian Ringgit", "Asia & Gulf", "RM"),
    ("NZD", "New Zealand Dollar", "Major", "NZ$"),
]


def load_rates():
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
    _ = sys.stdin.read()
    rates, source = load_rates()
    items = []
    for code, name, cat, sym in META:
        r = float(rates.get(code, 0))
        if r <= 0:
            continue
        items.append({
            "id": code,
            "title": f"USD → {code} ({name})",
            "subtitle": f"1 USD = {r:.4f} {code} · $100 = {sym} {r*100:,.2f}",
            "icon": "dollarsign.circle.fill",
            "category": cat,
            "accessories": [
                {"kind": "tag", "text": cat, "color": "#10B981" if cat == "Major" else "#38BDF8"},
                {"kind": "metric", "text": f"{r:.4f}"}
            ],
            "detail": {
                "markdown": f"### 1 USD = {r:.4f} {code}\n\n**Currency:** {name}\n\n- **$10 USD:** {r*10:,.2f} {code}\n- **$100 USD:** {r*100:,.2f} {code}\n- **$1,000 USD:** {r*1000:,.2f} {code}",
                "metadata": [
                    {"label": "Pair", "value": f"USD/{code}", "color": "#10B981"},
                    {"label": "Rate", "value": f"{r:.4f}"},
                    {"label": "Source", "value": source},
                ]
            },
            "actions": [
                {"id": "copy-rate", "title": f"Copy {r:.4f} {code}", "icon": "doc.on.doc", "shortcut": "↵", "kind": "copy", "value": f"{r:.4f}"},
                {"id": "copy-pair", "title": "Copy Rate Line", "icon": "text.quote", "shortcut": "⌘C", "kind": "copy", "value": f"1 USD = {r:.4f} {code}"},
            ]
        })
    print(json.dumps({
        "items": items,
        "filter_options": ["All", "Major", "Asia & Gulf"],
        "empty_message": "No currencies matched."
    }))


if __name__ == "__main__":
    main()

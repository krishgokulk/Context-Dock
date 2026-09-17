// Context-Dock
//
// The plugins the app ships with. These are AUTHORED — written as manifests the way a plugin
// author would write them — not converted from the old Global Commands. That is the point of
// them: they are the first honest test of whether the format is pleasant to write in, and
// whatever is awkward here will be awkward for everybody else.
//
// They are seeded onto disk rather than bundled as a resource folder, so they live in the same
// place every other plugin does and can be read, edited or deleted by hand. Seeding never
// overwrites an edit: a pack that rewrites itself at every launch is a pack nobody can change.

import Foundation

enum PluginEssentials {
    static let packID = "essentials"
    static let packName = "Essentials"

    /// Put the Mac to sleep.
    ///
    /// The whole plugin, and worth reading as a measure of the format: eleven lines of JSON
    /// for something that needed a `SystemCommand` record, a registry entry and a row in the
    /// dock's own switch before.
    ///
    /// `replaces:Sleep` retires the built-in Global Command of the same name while this is
    /// installed. Two rows called Sleep answered to one search, and the old one's ⏎ opened a
    /// presets panel rather than sleeping — which is what "sleep isn't working" was.
    ///
    /// No `views`. A plugin with a `primaryAction` and no panel is a one-shot: ⏎ runs it.
    /// `risk: medium` because it interrupts whatever the machine is doing — `read` would run
    /// it the moment a fuzzy match put it under the cursor and somebody pressed return.
    static let sleepJSON = """
    {
      "id": "sleep",
      "name": "Sleep",
      "icon": "moon.zzz.fill",
      "description": "Put this Mac to sleep.",
      "keywords": ["sleep", "suspend", "replaces:Sleep"],
      "inputs": [],
      "actions": {
        "sleep": {
          "type": "bash",
          "script": "pmset sleepnow",
          "title": "Sleep now",
          "risk": "medium",
          "success": { "title": "Sleeping", "message": "" }
        }
      },
      "primaryAction": "sleep"
    }
    """

    /// The rates script, kept as a raw string so its backslashes and quotes read as written
    /// and are JSON-escaped once, below, rather than by hand in a JSON literal.
    ///
    /// Frankfurter (ECB rates, no key) when the network answers; a small built-in table when
    /// it does not, marked `offline` so the tile can say so. `amount=` makes the API do the
    /// multiplication, so the figure under the currency's key is already the answer. The
    /// `.dev/v1` host is the current one — `.app` answers with a 301 that `curl -fsS` treats
    /// as an HTML page, and following it would reach a host the manifest never declared.
    static let currencyScript = #"""
    from="${CD_STATE_FROM:-USD}"; to="${CD_STATE_TO:-EUR}"; amt="${CD_STATE_AMOUNT:-500}"
    case "$amt" in ''|*[!0-9.]*) amt=500;; esac
    body=$(curl -fsS --max-time 4 "https://api.frankfurter.dev/v1/latest?amount=${amt}&base=${from}&symbols=${to}" 2>/dev/null)
    result=$(printf '%s' "$body" | awk -v k="$to" '{ n=index($0, "\"" k "\":"); if (n) { s=substr($0, n+length(k)+3); sub(/[^0-9.].*/, "", s); print s } }')
    offline=false
    if [ -z "$result" ]; then
      offline=true
      result=$(awk -v a="$amt" -v f="$from" -v t="$to" 'BEGIN {
        r["USD"]=1; r["EUR"]=0.92; r["GBP"]=0.79; r["CHF"]=0.88; r["JPY"]=150; r["CNY"]=7.2;
        r["INR"]=83; r["AED"]=3.67; r["TRY"]=34; r["PLN"]=4.0; r["CAD"]=1.36; r["AUD"]=1.52;
        r["SEK"]=10.5; r["NOK"]=10.7; r["KRW"]=1330; r["SGD"]=1.34;
        if (!(f in r) || !(t in r)) { print ""; exit }
        printf "%.4f", a / r[f] * r[t] }')
    fi
    [ -z "$result" ] && result=0
    pretty=$(awk -v v="$result" 'BEGIN { printf "%'"'"'.2f", v }')
    printf '{"result":"%s","pair":"%s → %s","offline":%s,"currencies":[' "$pretty" "$from" "$to" "$offline"
    first=1
    for c in USD EUR GBP CHF JPY CNY INR AED TRY PLN CAD AUD SEK NOK KRW SGD; do
      [ $first -eq 1 ] || printf ','
      printf '{"code":"%s"}' "$c"; first=0
    done
    printf ']}\n'
    """#

    /// Swap the two currencies. A script action whose output carries `state` changes what
    /// the plugin remembers; the runtime asks for the rate again with the pair reversed.
    static let currencySwapScript = #"""
    printf '{"state":{"from":"%s","to":"%s"}}\n' "${CD_STATE_TO:-EUR}" "${CD_STATE_FROM:-USD}"
    """#

    /// A currency converter that lives in the dock strip as a bar tile — the amount over
    /// the result, the two currencies as chips beside them — and opens its picker as a card
    /// above the tile. The first plugin with `state`: the pair and the amount survive a
    /// relaunch, and every tap is a `set` the data script reads on its next run.
    static var currencyJSON: String {
        let data = jsonString(currencyScript)
        let swap = jsonString(currencySwapScript)
        return """
        {
          "id": "currency",
          "name": "Currency",
          "icon": "dollarsign.arrow.circlepath",
          "description": "Convert an amount between currencies, live from the ECB.",
          "keywords": ["currency", "convert", "exchange", "usd", "eur", "gbp", "rate"],
          "inputs": [],
          "permissions": ["network:api.frankfurter.dev"],
          "state": { "from": "USD", "to": "EUR", "amount": "500", "picking": "from" },
          "data": { "type": "bash", "script": \(data), "format": "json",
                    "refresh": { "widget": 600, "panel": 0 }, "timeout": 8 },
          "sample": { "result": "433.36", "pair": "USD → EUR", "offline": false,
                      "currencies": [ { "code": "USD" }, { "code": "EUR" }, { "code": "GBP" },
                                      { "code": "CHF" }, { "code": "JPY" }, { "code": "CNY" } ] },
          "actions": {
            "pickFrom":  { "type": "push:panel", "key": "picking", "value": "from", "title": "Convert from" },
            "pickTo":    { "type": "push:panel", "key": "picking", "value": "to", "title": "Convert to" },
            "choose":    { "type": "set", "key": "{{picking}}", "title": "Choose" },
            "setAmount": { "type": "set", "key": "amount", "title": "Amount" },
            "swap":      { "type": "bash", "script": \(swap), "title": "Swap", "risk": "read" }
          },
          "views": {
            "widget": { "family": "bar", "slots": 3,
              "root": { "hstack": [
                { "vstack": [
                    { "caption": { "text": "{{amount}} {{from}}", "value": "{{amount}}", "edit": "setAmount" } },
                    { "title": "{{result}}" } ] },
                { "iconButton": { "icon": "arrow.up.arrow.down", "action": "swap" } },
                { "vstack": [
                    { "button": { "title": "{{from}}", "action": "pickFrom" } },
                    { "button": { "title": "{{to}}", "action": "pickTo" } } ] }
              ] } },
            "panel": { "vstack": [
              { "header": { "text": "Convert {{picking}}", "icon": "dollarsign.arrow.circlepath" } },
              { "grid": { "columns": 2, "items": "{{currencies}}",
                          "cell": { "button": { "title": "{{item.code}}", "action": "choose",
                                                "value": "{{item.code}}" } } } }
            ] }
          }
        }
        """
    }

    static var all: [PluginManifest] { [decode(sleepJSON), decode(currencyJSON)].compactMap { $0 } }

    /// A string as a JSON string literal, quotes included — so a script can be written as it
    /// is run and embedded without hand-escaping.
    private static func jsonString(_ raw: String) -> String {
        guard let data = try? JSONEncoder().encode(raw), let text = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return text
    }

    /// Write the shipped plugins where the registry reads them, skipping any whose manifest
    /// is already on disk — an edited one stays edited, and a deleted one stays deleted until
    /// the app is reinstalled.
    static func seed(into root: URL) throws {
        let folder = root.appendingPathComponent(packID, isDirectory: true)
        let pluginsDir = folder.appendingPathComponent("plugins", isDirectory: true)
        let missing = all.filter { manifest in
            !FileManager.default.fileExists(
                atPath: pluginsDir
                    .appendingPathComponent("\(manifest.id)/manifest.json").path)
        }
        guard !missing.isEmpty else { return }
        try PluginInstaller.install(missing, into: root, packID: packID, packName: packName)
    }

    @MainActor
    static func seedIfNeeded() {
        do {
            try seed(into: PluginInstaller.userRoot)
        } catch {
            // A failure here costs the shipped plugins, not the app. The Plugins page shows
            // what actually loaded, which is the honest place to notice.
            NSLog("Context-Dock: could not seed the Essentials plugins — \(error)")
        }
    }

    private static func decode(_ json: String) -> PluginManifest? {
        try? JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }
}

/// What choosing a plugin does.
enum PluginLaunchBehaviour: Equatable {
    /// Show its panel — the richer surface, and it contains the actions anyway.
    case openPanel
    /// Run this action. A plugin with no panel is a one-shot; opening an empty window for it
    /// would be a worse answer than doing the thing.
    case run(String)
    /// Neither: an agent-only plugin, or one whose author declared nothing to show or do.
    case nothing
}

enum PluginLaunch {
    static func behaviour(for manifest: PluginManifest) -> PluginLaunchBehaviour {
        if manifest.views.panel != nil || manifest.views.window != nil { return .openPanel }
        if let primary = manifest.primaryAction, manifest.actions[primary] != nil {
            return .run(primary)
        }
        return .nothing
    }
}

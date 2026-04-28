// SafariCommandBridge.swift
// Context-Dock
//
// Three-tier Safari control — ordered by speed, no wasted tokens:
//
//  Tier 1  parseIntent()   — keyword match, INSTANT, zero AI, works offline/on-device
//  Tier 2  parseTag()      — cloud AI emits a compact tag, dock executes it
//  Tier 3  (none)          — on-device AI gets no menu injection, relies on Tier 1 only

import Foundation
import AppKit

// MARK: - Search Engine

enum SearchEngine: String {
    case google     = "google"
    case youtube    = "youtube"
    case amazon     = "amazon"
    case duckduckgo = "duckduckgo"

    func url(for query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .google:     return "https://www.google.com/search?q=\(encoded)"
        case .youtube:    return "https://www.youtube.com/results?search_query=\(encoded)"
        case .amazon:     return "https://www.amazon.com/s?k=\(encoded)"
        case .duckduckgo: return "https://duckduckgo.com/?q=\(encoded)"
        }
    }

    static func detect(from text: String) -> SearchEngine {
        let q = text.lowercased()
        if q.contains("youtube")                          { return .youtube }
        if q.contains("amazon")                           { return .amazon }
        if q.contains("ddg") || q.contains("duckduckgo") { return .duckduckgo }
        return .google
    }
}

// MARK: - Commands

enum SafariCommand {
    case menuItem(menu: String, item: String)          // AppleScript menu click — no JS needed
    case openTab(url: String)
    case searchNewTab(query: String, engine: SearchEngine)
    case closeCurrentTab
    case runPageJS(script: String)
    case highlightText(text: String)
    case scrollToSelector(css: String)
    case scrapeSelector(css: String, attribute: String?)
    case extractPrices
    case fillField(selector: String, value: String)
    case clickElement(selector: String)
}

// MARK: - Menu Map
// Single source of truth for NL aliases AND the compact cloud-AI prompt.

private struct MenuEntry {
    let aliases: [String]   // every NL phrase that should trigger this action
    let menu: String
    let item: String
    let tag: String         // compact tag string for cloud AI prompt
}

private let safariMenuMap: [MenuEntry] = [
    // ── Window management ─────────────────────────────────────────────────────
    MenuEntry(
        aliases: ["minimise window", "minimize window", "minimise safari", "minimize safari", "minimise"],
        menu: "Window", item: "Minimise",
        tag: "[SAFARI_MENU: Window > Minimise]"
    ),
    MenuEntry(
        aliases: ["zoom window", "zoom safari", "maximise window", "maximize window", "zoom"],
        menu: "Window", item: "Zoom",
        tag: "[SAFARI_MENU: Window > Zoom]"
    ),
    MenuEntry(
        aliases: ["fill screen", "fill window", "fill"],
        menu: "Window", item: "Fill",
        tag: "[SAFARI_MENU: Window > Fill]"
    ),
    MenuEntry(
        aliases: ["centre window", "center window", "centre", "center"],
        menu: "Window", item: "Centre",
        tag: "[SAFARI_MENU: Window > Centre]"
    ),
    MenuEntry(
        aliases: ["bring all to front", "bring to front", "bring all windows"],
        menu: "Window", item: "Bring All to Front",
        tag: "[SAFARI_MENU: Window > Bring All to Front]"
    ),

    // ── Tab navigation ────────────────────────────────────────────────────────
    MenuEntry(
        aliases: ["next tab", "switch tab", "go to next tab", "show next tab", "forward tab"],
        menu: "Window", item: "Show Next Tab",
        tag: "[SAFARI_MENU: Window > Show Next Tab]"
    ),
    MenuEntry(
        aliases: ["previous tab", "prev tab", "go back tab", "show previous tab", "last tab", "prior tab", "switch previous tab", "back tab"],
        menu: "Window", item: "Show Previous Tab",
        tag: "[SAFARI_MENU: Window > Show Previous Tab]"
    ),
    MenuEntry(
        aliases: ["next tab group", "go to next group"],
        menu: "Window", item: "Go To Next Tab Group",
        tag: "[SAFARI_MENU: Window > Go To Next Tab Group]"
    ),
    MenuEntry(
        aliases: ["previous tab group", "prev tab group", "go to previous group"],
        menu: "Window", item: "Go To Previous Tab Group",
        tag: "[SAFARI_MENU: Window > Go To Previous Tab Group]"
    ),

    // ── Tab operations ────────────────────────────────────────────────────────
    MenuEntry(
        aliases: ["pin tab", "pin this tab", "lock tab"],
        menu: "Window", item: "Pin Tab",
        tag: "[SAFARI_MENU: Window > Pin Tab]"
    ),
    MenuEntry(
        aliases: ["duplicate tab", "duplicate this tab", "copy tab", "clone tab"],
        menu: "Window", item: "Duplicate Tab",
        tag: "[SAFARI_MENU: Window > Duplicate Tab]"
    ),
    MenuEntry(
        aliases: ["move tab to new window", "pop tab out", "detach tab", "move to new window"],
        menu: "Window", item: "Move Tab to New Window",
        tag: "[SAFARI_MENU: Window > Move Tab to New Window]"
    ),
    MenuEntry(
        aliases: ["mute tab", "mute this tab", "silence tab", "mute audio", "mute sound"],
        menu: "Window", item: "Mute This Tab",
        tag: "[SAFARI_MENU: Window > Mute This Tab]"
    ),
    MenuEntry(
        aliases: ["mute other tabs", "mute all other tabs", "silence other tabs", "mute others"],
        menu: "Window", item: "Mute Other Tabs",
        tag: "[SAFARI_MENU: Window > Mute Other Tabs]"
    ),
    MenuEntry(
        aliases: ["arrange tabs", "sort tabs", "organize tabs"],
        menu: "Window", item: "Arrange Tabs By",
        tag: "[SAFARI_MENU: Window > Arrange Tabs By]"
    ),
    MenuEntry(
        aliases: ["merge windows", "merge all windows", "combine windows"],
        menu: "Window", item: "Merge All Windows",
        tag: "[SAFARI_MENU: Window > Merge All Windows]"
    ),

    // ── New tab / window ──────────────────────────────────────────────────────
    MenuEntry(
        aliases: ["new tab", "open tab", "open a new tab", "create tab", "add tab"],
        menu: "File", item: "New Tab",
        tag: "[SAFARI_MENU: File > New Tab]"
    ),
    MenuEntry(
        aliases: ["new private window", "private window", "incognito", "private browsing", "open private"],
        menu: "File", item: "New Private Window",
        tag: "[SAFARI_MENU: File > New Private Window]"
    ),
    MenuEntry(
        aliases: ["new work window", "work window"],
        menu: "File", item: "New Work Window",
        tag: "[SAFARI_MENU: File > New Work Window]"
    ),

    // ── Close ─────────────────────────────────────────────────────────────────
    MenuEntry(
        aliases: ["close window", "close this window", "shut window"],
        menu: "File", item: "Close Window",
        tag: "[SAFARI_MENU: File > Close Window]"
    ),
    MenuEntry(
        aliases: ["close all windows", "close every window"],
        menu: "File", item: "Close All Windows",
        tag: "[SAFARI_MENU: File > Close All Windows]"
    ),

    // ── Save / export ─────────────────────────────────────────────────────────
    MenuEntry(
        aliases: ["save page", "save as", "save this page", "download page"],
        menu: "File", item: "Save As\u{2026}",
        tag: "[SAFARI_MENU: File > Save As…]"
    ),
    MenuEntry(
        aliases: ["export pdf", "save pdf", "export as pdf", "save as pdf", "download pdf"],
        menu: "File", item: "Export as PDF\u{2026}",
        tag: "[SAFARI_MENU: File > Export as PDF…]"
    ),
    MenuEntry(
        aliases: ["print", "print page", "print this page", "print tab"],
        menu: "File", item: "Print\u{2026}",
        tag: "[SAFARI_MENU: File > Print…]"
    ),
    MenuEntry(
        aliases: ["share page", "share this page", "share tab", "share link"],
        menu: "File", item: "Share\u{2026}",
        tag: "[SAFARI_MENU: File > Share…]"
    ),
]

// MARK: - Bridge

@MainActor
final class SafariCommandBridge {
    static let shared = SafariCommandBridge()
    private init() {}

    // MARK: - Execute

    func execute(_ command: SafariCommand) async -> String {
        switch command {

        case .menuItem(let menu, let item):
            return clickSafariMenu(menu: menu, item: item)

        case .openTab(let url):
            SafariTabManager.shared.openURL(url)
            return "Opened \(url)"

        case .searchNewTab(let query, let engine):
            SafariTabManager.shared.openURL(engine.url(for: query))
            return "Searching \"\(query)\" on \(engine.rawValue)"

        case .closeCurrentTab:
            return clickSafariMenu(menu: "File", item: "Close Tab")

        case .runPageJS(let script):
            let result = await SafariTabManager.shared.executeJS(script) ?? ""
            return result.isEmpty ? "Script executed" : result

        case .highlightText(let text):
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function(){
                var walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
                var nodes=[],node;
                while(node=walker.nextNode())nodes.push(node);
                var re=new RegExp('\(escaped)','gi');
                nodes.forEach(function(n){
                    if(!re.test(n.textContent))return;
                    var s=document.createElement('span');
                    s.innerHTML=n.textContent.replace(re,'<mark style="background:#FFD60A;color:#000;border-radius:2px">$&</mark>');
                    n.parentNode.replaceChild(s,n);
                });
                return 'Highlighted: \(escaped)';
            })()
            """
            return await SafariTabManager.shared.executeJS(js) ?? "Done"

        case .scrollToSelector(let css):
            let esc = css.replacingOccurrences(of: "'", with: "\\'")
            let js = "(function(){var el=document.querySelector('\(esc)');if(el){el.scrollIntoView({behavior:'smooth',block:'center'});return 'Scrolled to \(esc)';}return 'Not found: \(esc)';})()";
            return await SafariTabManager.shared.executeJS(js) ?? "Done"

        case .scrapeSelector(let css, let attribute):
            let esc = css.replacingOccurrences(of: "'", with: "\\'")
            let attr = attribute ?? ""
            let js = """
            (function(){
                var els=Array.from(document.querySelectorAll('\(esc)'));
                if(!els.length)return 'No elements: \(esc)';
                return els.slice(0,20).map(function(e){
                    return '\(attr)'.length?(e.getAttribute('\(attr)')||''):e.innerText.trim();
                }).filter(Boolean).join('\\n');
            })()
            """
            return await SafariTabManager.shared.executeJS(js) ?? "Nothing found"

        case .extractPrices:
            let js = """
            (function(){
                var prices=(document.body.innerText.match(/[$€£¥₹]\\s?[\\d,]+\\.?\\d{0,2}/g)||[]);
                var u=[...new Set(prices)].slice(0,30);
                return u.length?u.join('\\n'):'No prices found';
            })()
            """
            return await SafariTabManager.shared.executeJS(js) ?? "No prices found"

        case .fillField(let selector, let value):
            let esc = selector.replacingOccurrences(of: "'", with: "\\'")
            let val = value.replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function(){
                var el=document.querySelector('\(esc)');
                if(!el)return 'Field not found: \(esc)';
                el.focus();
                Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value')
                    .set.call(el,'\(val)');
                el.dispatchEvent(new Event('input',{bubbles:true}));
                el.dispatchEvent(new Event('change',{bubbles:true}));
                return 'Filled: \(val)';
            })()
            """
            return await SafariTabManager.shared.executeJS(js) ?? "Done"

        case .clickElement(let selector):
            let esc = selector.replacingOccurrences(of: "'", with: "\\'")
            let js = "(function(){var el=document.querySelector('\(esc)');if(!el)return 'Not found: \(esc)';el.click();return 'Clicked: \(esc)';})()";
            return await SafariTabManager.shared.executeJS(js) ?? "Done"
        }
    }

    // MARK: - Tier 1: Natural Language Parser (instant, zero AI)

    /// Covers ~90% of Safari commands without any AI call.
    /// Expand aliases here — never send a menu list to on-device AI.
    func parseIntent(_ query: String) -> SafariCommand? {
        let q = query.lowercased()

        // ── "search X in new tab" — must run BEFORE menuMap so "new tab" alias
        //    in the menuMap entry doesn't steal "search X in new tab" queries ─────
        if q.contains("new tab") || q.contains("open tab") {
            let engine = SearchEngine.detect(from: q)
            let stripped = stripSearchNoise(q, engine: engine)
            if !stripped.isEmpty {
                return .searchNewTab(query: stripped, engine: engine)
            }
            return .menuItem(menu: "File", item: "New Tab")
        }

        // ── Click / tap / play element by visible text ───────────────────────
        if q.hasPrefix("click ") || q.hasPrefix("tap ") || q.hasPrefix("press ")
            || q.hasPrefix("play ") || q.hasPrefix("open video ") || q.hasPrefix("watch ")
        {
            var term = q
                .replacingOccurrences(
                    of: "^(click|tap|press|play|watch|open video)\\s+",
                    with: "", options: .regularExpression
                )
                // Strip trailing context phrases
                .replacingOccurrences(of: " from this page", with: "")
                .replacingOccurrences(of: " on this page", with: "")
                .replacingOccurrences(of: " on the page", with: "")
                .replacingOccurrences(of: " from the page", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty {
                let esc = term.replacingOccurrences(of: "'", with: "\\'")
                let js = """
                (function(){
                    var t='\(esc)'.toLowerCase();
                    var hits=Array.from(document.querySelectorAll('a,button,[role="button"],[role="link"],[onclick]'));
                    var el=hits.find(function(e){return e.textContent.toLowerCase().includes(t);});
                    if(!el){
                        var all=Array.from(document.querySelectorAll('*'));
                        el=all.find(function(e){return e.childElementCount===0&&e.textContent.toLowerCase().trim().includes(t);});
                    }
                    if(el){el.scrollIntoView({block:'center'});el.click();return 'Clicked: '+el.textContent.trim().slice(0,60);}
                    return 'No element found matching: \(esc)';
                })()
                """
                return .runPageJS(script: js)
            }
        }

        // Menu map — O(n) alias scan, instant
        for entry in safariMenuMap {
            if entry.aliases.contains(where: { q.contains($0) }) {
                return .menuItem(menu: entry.menu, item: entry.item)
            }
        }

        // YouTube / Amazon targeted searches (with engine keyword in query)
        if q.contains("youtube") && (q.contains("search") || q.contains("watch") || q.contains("find")) {
            return .searchNewTab(query: stripSearchNoise(q, engine: .youtube), engine: .youtube)
        }
        if q.contains("amazon") && (q.contains("search") || q.contains("buy") || q.contains("price") || q.contains("find")) {
            return .searchNewTab(query: stripSearchNoise(q, engine: .amazon), engine: .amazon)
        }

        // ── Bare "search X" / "find X" (no engine or "new tab" needed) ────────
        if q.hasPrefix("search ") || q.hasPrefix("find ") {
            let engine = SearchEngine.detect(from: q)
            let stripped = stripSearchNoise(q, engine: engine)
            if !stripped.isEmpty { return .searchNewTab(query: stripped, engine: engine) }
        }

        // ── "open <url or name>" ───────────────────────────────────────────────
        // Exclude "open tab", "open a new tab" etc. — those are caught by menuMap above.
        if q.hasPrefix("open ") && !q.contains("tab") && !q.contains("window") {
            let term = String(q.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty {
                if !term.contains(" ") && term.contains(".") {
                    let url = term.hasPrefix("http") ? term : "https://\(term)"
                    return .openTab(url: url)
                }
                let engine = SearchEngine.detect(from: term)
                return .searchNewTab(query: term, engine: engine)
            }
        }
        // ── "go to <url or name>" ─────────────────────────────────────────────
        if q.hasPrefix("go to ") {
            let term = String(q.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty {
                if !term.contains(" ") && term.contains(".") {
                    let url = term.hasPrefix("http") ? term : "https://\(term)"
                    return .openTab(url: url)
                }
                let engine = SearchEngine.detect(from: term)
                return .searchNewTab(query: term, engine: engine)
            }
        }

        // Page content actions
        if q.contains("price") && (q.contains("find") || q.contains("show") || q.contains("extract") || q.contains("this page") || q.contains("current page") || q.contains("page")) {
            return .extractPrices
        }
        if q.contains("highlight") {
            let term = q
                .replacingOccurrences(of: "highlight", with: "")
                .replacingOccurrences(of: "on the page", with: "")
                .replacingOccurrences(of: "on this page", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty { return .highlightText(text: term) }
        }

        // Close tab — matched last so "close window" is caught by menuMap above
        if q.contains("close") && (q.contains("tab") || q.contains("this")) {
            return .closeCurrentTab
        }

        return nil
    }

    // MARK: - Tier 2: Tag Parser (cloud AI responses only)

    func parseTag(from response: String) -> SafariCommand? {
        if let m = match(response, pattern: #"\[SAFARI_MENU:\s*([^\]]+)\]"#) {
            let parts = m.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 { return .menuItem(menu: parts[0], item: parts[1]) }
        }
        if let m = match(response, pattern: #"\[SAFARI_OPEN_TAB:\s*([^\]]+)\]"#) {
            return .openTab(url: m.trimmingCharacters(in: .whitespaces))
        }
        if let m = match(response, pattern: #"\[SAFARI_SEARCH:\s*([^\]]+)\]"#) {
            let parts = m.components(separatedBy: "@")
            let query  = parts[0].trimmingCharacters(in: .whitespaces)
            let engine = parts.count > 1
                ? SearchEngine(rawValue: parts[1].trimmingCharacters(in: .whitespaces)) ?? .google
                : .google
            return .searchNewTab(query: query, engine: engine)
        }
        if let m = match(response, pattern: #"\[SAFARI_PAGE_JS:\s*([\s\S]*?)\]"#) {
            return .runPageJS(script: m)
        }
        if response.contains("[SAFARI_PRICES]")    { return .extractPrices }
        if let m = match(response, pattern: #"\[SAFARI_HIGHLIGHT:\s*([^\]]+)\]"#) {
            return .highlightText(text: m.trimmingCharacters(in: .whitespaces))
        }
        if let m = match(response, pattern: #"\[SAFARI_SCRAPE:\s*([^\]]+)\]"#) {
            return .scrapeSelector(css: m.trimmingCharacters(in: .whitespaces), attribute: nil)
        }
        if let m = match(response, pattern: #"\[SAFARI_CLICK:\s*([^\]]+)\]"#) {
            return .clickElement(selector: m.trimmingCharacters(in: .whitespaces))
        }
        if response.contains("[SAFARI_CLOSE_TAB]") { return .closeCurrentTab }
        return nil
    }

    // MARK: - Cloud AI System Prompt (compact — ~80 tokens, never sent to on-device)

    /// Compact tag-only list for cloud AI providers (OpenAI / Anthropic / Gemini / Ollama).
    /// On-device AI receives nothing — Tier 1 parseIntent() handles it instead.
    static var compactSystemPromptBlock: String {
        let menuTags = safariMenuMap.map { "  \($0.tag)" }.joined(separator: "\n")
        return """
        ## Safari Control Tags (emit ONE if user asks to interact with Safari)
        Tab/window (menu):
        \(menuTags)
        Open/search:
          [SAFARI_OPEN_TAB: url]  [SAFARI_SEARCH: query@google|youtube|amazon|duckduckgo]
        Page actions:
          [SAFARI_PRICES]  [SAFARI_HIGHLIGHT: text]  [SAFARI_SCRAPE: css]
          [SAFARI_CLICK: css]  [SAFARI_PAGE_JS: js]  [SAFARI_CLOSE_TAB]
        Rule: wrap in one sentence. Example: "Switching tabs. [SAFARI_MENU: Window > Show Next Tab]"
        CRITICAL: NEVER emit [TERMINAL_COMMAND] or [EXECUTE_COMMAND] when Safari is frontmost. Always use SAFARI_ tags for every browser action, including clicking links, searching, and navigating.
        """
    }

    // MARK: - AppleScript menu click

    @discardableResult
    private func clickSafariMenu(menu: String, item: String) -> String {
        let script = """
        tell application "System Events"
            tell process "Safari"
                click menu item "\(item)" of menu "\(menu)" of menu bar 1
            end tell
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let err = error { return "Menu error: \(err)" }
        return "\(item) ✓"
    }
}

// MARK: - Private helpers

private extension SafariCommandBridge {
    func match(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    func stripSearchNoise(_ query: String, engine: SearchEngine) -> String {
        var s = query
        let noise = ["search for", "search", "find", "look up", "watch", "buy",
                     "on \(engine.rawValue)", engine.rawValue,
                     "in new tab", "new tab", "open tab", "for me", "please"]
        for word in noise {
            s = s.replacingOccurrences(of: word, with: "", options: .caseInsensitive)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

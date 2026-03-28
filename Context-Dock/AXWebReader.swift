// AXWebReader.swift
// Context-Dock
//
// Extracts visible text from a browser's AX web area so AI queries can be
// grounded in the actual live page content — no browser extension required.
// Call refresh() from a background thread; read cachedText() from anywhere.

import AppKit
import ApplicationServices

// MARK: - Page Snapshot

struct PageSnapshot {
    let url: String
    let text: String       // structured, budget-trimmed page text
    let title: String
    let timestamp: Date

    /// Stale after 45 seconds (page content rarely changes faster)
    var isStale: Bool { Date().timeIntervalSince(timestamp) > 45 }
}

// MARK: - AXWebReader

final class AXWebReader {
    static let shared = AXWebReader()
    private init() {}

    // pid → latest snapshot
    private var cache: [pid_t: PageSnapshot] = [:]

    private let browserBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "org.chromium.Chromium",
    ]

    // MARK: - Public API

    func isBrowser(bundleId: String) -> Bool {
        browserBundleIds.contains(bundleId)
            || bundleId.hasPrefix("com.apple.Safari")
            || bundleId.lowercased().contains("browser")
    }

    /// Returns cached text immediately (nil if not yet cached or stale).
    func cachedSnapshot(for pid: pid_t) -> PageSnapshot? {
        guard let snap = cache[pid], !snap.isStale else { return nil }
        return snap
    }

    /// Extracts text from the browser's web area. Call on a background thread.
    /// Stores result in cache; retrieve with cachedSnapshot(for:).
    func refresh(pid: pid_t, currentURL: String) {
        // Skip if cache is fresh and URL hasn't changed
        if let cached = cache[pid], !cached.isStale, cached.url == currentURL { return }

        let axApp = AXUIElementCreateApplication(pid)

        // Find AXWebArea starting from the focused window
        guard let webArea = findWebArea(axApp) else { return }

        var chunks: [TextChunk] = []
        var visited = 0
        walkWebArea(webArea, into: &chunks, depth: 0, visited: &visited)

        let text  = buildBudgetedText(from: chunks, budget: 9000)
        let title = readTitle(axApp)

        cache[pid] = PageSnapshot(
            url: currentURL,
            text: text,
            title: title,
            timestamp: Date()
        )
    }

    /// Invalidate cache for a pid (e.g. when user navigates to a new page).
    func invalidate(pid: pid_t) {
        cache.removeValue(forKey: pid)
    }

    // MARK: - Internal chunk model

    private struct TextChunk {
        enum Kind { case heading(level: Int), body, link }
        let kind: Kind
        let text: String

        var priority: Int {
            switch kind {
            case .heading(let l): return 10 - min(l, 6)  // h1=9, h2=8 …
            case .body:           return 5
            case .link:           return 2
            }
        }
    }

    // MARK: - Tree traversal

    /// BFS from the app root — finds the AXWebArea element.
    /// Also checks AXScrollArea + role description for Chromium-based browsers (Arc, Brave, Edge)
    /// that may sandbox their renderer process but expose an AXScrollArea with role desc "web content".
    /// Caps at 800 nodes so we don't hang on complex chrome UIs.
    private func findWebArea(_ app: AXUIElement) -> AXUIElement? {
        var queue: [AXUIElement] = [app]
        var visited = 0
        var bestScrollArea: AXUIElement? = nil  // fallback for Chromium
        while !queue.isEmpty, visited < 800 {
            let elem = queue.removeFirst()
            visited += 1

            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""

            if role == "AXWebArea" { return elem }

            // Chromium fallback: AXScrollArea whose role description contains "web"
            if role == "AXScrollArea" {
                var descRef: CFTypeRef?
                AXUIElementCopyAttributeValue(elem, kAXRoleDescriptionAttribute as CFString, &descRef)
                let desc = (descRef as? String ?? "").lowercased()
                if desc.contains("web") && bestScrollArea == nil {
                    bestScrollArea = elem
                }
            }

            var childRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &childRef) == .success,
               let children = childRef as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(20)) // skip very wide toolbar subtrees
            }
        }
        return bestScrollArea  // nil for non-browser apps; AXScrollArea for Chromium when AXWebArea absent
    }

    /// DFS walk of the web area. Caps at 3000 nodes to stay under 500 ms on large pages.
    private func walkWebArea(
        _ elem: AXUIElement,
        into chunks: inout [TextChunk],
        depth: Int,
        visited: inout Int
    ) {
        guard depth < 40, visited < 3000 else { return }
        visited += 1

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        switch role {
        case "AXHeading":
            var levelRef: CFTypeRef?
            AXUIElementCopyAttributeValue(elem, "AXARIALevel" as CFString, &levelRef)
            let level = (levelRef as? Int) ?? 1
            if let text = textValue(elem), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                chunks.append(TextChunk(kind: .heading(level: level), text: text))
            }
            return // headings typically have no meaningful children beyond the text

        case "AXStaticText":
            if let text = textValue(elem) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 20 {
                    chunks.append(TextChunk(kind: .body, text: trimmed))
                }
            }
            return // leaf node

        case "AXLink":
            if let text = textValue(elem) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    chunks.append(TextChunk(kind: .link, text: trimmed))
                }
            }
            // Don't recurse into links — their children are usually just the label text

        case "AXImage":
            var descRef: CFTypeRef?
            AXUIElementCopyAttributeValue(elem, kAXDescriptionAttribute as CFString, &descRef)
            if let desc = descRef as? String, !desc.isEmpty {
                chunks.append(TextChunk(kind: .body, text: "[Image: \(desc)]"))
            }
            return

        case "AXTable":
            extractTableText(elem, into: &chunks)
            return

        default:
            break
        }

        // Recurse into children
        var childRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return }
        for child in children {
            walkWebArea(child, into: &chunks, depth: depth + 1, visited: &visited)
        }
    }

    /// Special handling for AXTable — extract rows as tab-separated lines.
    private func extractTableText(_ table: AXUIElement, into chunks: inout [TextChunk]) {
        var rowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(table, kAXRowsAttribute as CFString, &rowRef) == .success,
              let rows = rowRef as? [AXUIElement] else { return }

        for row in rows.prefix(30) { // cap at 30 rows to stay inside budget
            var cellRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(row, kAXChildrenAttribute as CFString, &cellRef) == .success,
                  let cells = cellRef as? [AXUIElement] else { continue }
            let cellTexts = cells.compactMap { textValue($0) }.filter { !$0.isEmpty }
            if !cellTexts.isEmpty {
                chunks.append(TextChunk(kind: .body, text: cellTexts.joined(separator: "\t")))
            }
        }
    }

    // MARK: - Budget-aware text assembly

    /// Assembles chunks into a structured string within `budget` characters.
    /// Headings always get priority; body text fills the rest.
    private func buildBudgetedText(from chunks: [TextChunk], budget: Int) -> String {
        // Deduplicate consecutive identical lines (common in navbars / footers)
        var deduped: [TextChunk] = []
        var seen = Set<String>()
        for chunk in chunks {
            if seen.insert(chunk.text).inserted {
                deduped.append(chunk)
            }
        }

        var result = ""
        // First pass: headings (they define page structure)
        for chunk in deduped {
            guard case .heading(let level) = chunk.kind else { continue }
            let line = String(repeating: "#", count: min(level, 6)) + " " + chunk.text + "\n"
            if result.count + line.count > budget { break }
            result += line
        }
        // Second pass: body text
        for chunk in deduped {
            guard case .body = chunk.kind else { continue }
            let line = chunk.text + "\n"
            if result.count + line.count > budget { break }
            result += line
        }
        return result
    }

    // MARK: - Helpers

    private func textValue(_ elem: AXUIElement) -> String? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &ref) == .success,
           let s = ref as? String, !s.isEmpty { return s }
        if AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &ref) == .success,
           let s = ref as? String, !s.isEmpty { return s }
        return nil
    }

    private func readTitle(_ axApp: AXUIElement) -> String {
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let win = winRef {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success,
               let t = titleRef as? String { return t }
        }
        return ""
    }
}

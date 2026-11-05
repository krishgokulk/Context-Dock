import AppKit
import Foundation

/// First-party Safari capabilities for app-scoped chat and Frontmost App Agent turns.
/// Low-risk reads allow instant tab and page awareness; switching tabs brings target tab to front.
@MainActor
enum AppleSafariMCPCapabilities {
    static func register(in registry: CapabilityRegistry) {
        registerCurrentTab(registry)
        registerPageContent(registry)
        registerListTabs(registry)
        registerSwitchTab(registry)
    }

    private static func ensureEnabled() throws {
        guard AppSettings.shared.safariMCPEnabled else {
            throw AICapabilityError.blocked("Safari access is disabled in Settings.")
        }
    }

    // MARK: - safari.currentTab

    private static func registerCurrentTab(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "safari.currentTab",
                title: "Get Current Safari Tab",
                appBundleID: "com.apple.Safari",
                inputSchema: .init(fields: []),
                riskLevel: .low
            ) { _ in
                try ensureEnabled()
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty else {
                    return .init(success: false, output: "Safari is not running.")
                }

                // 1. Try BrowserPageReader (fresh extension context or accessibility)
                if let page = BrowserPageReader.current(bundleId: "com.apple.Safari"), !page.url.isEmpty {
                    let domain = URL(string: page.url)?.host ?? "unknown"
                    return .init(
                        success: true,
                        output: "Title: \(page.title)\nURL: \(page.url)\nDomain: \(domain)"
                    )
                }

                // 2. Headless AppleScript fallback for current tab
                let script = """
                tell application "Safari"
                    if (count of windows) > 0 then
                        tell current tab of front window
                            return (name as text) & "|||" & (URL as text)
                        end tell
                    end if
                    return ""
                end tell
                """
                var err: NSDictionary?
                let raw = NSAppleScript(source: script)?.executeSerialized(error: &err).stringValue ?? ""
                guard !raw.isEmpty else {
                    return .init(success: false, output: "No active Safari tab found.")
                }
                let parts = raw.components(separatedBy: "|||")
                let title = parts.first ?? ""
                let url = parts.count > 1 ? parts[1] : ""
                let domain = URL(string: url)?.host ?? "unknown"
                return .init(
                    success: true,
                    output: "Title: \(title)\nURL: \(url)\nDomain: \(domain)"
                )
            }
        )
    }

    // MARK: - safari.pageContent

    private static func registerPageContent(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "safari.pageContent",
                title: "Extract Page Content as Markdown",
                appBundleID: "com.apple.Safari",
                inputSchema: .init(fields: [
                    .init(name: "limit", description: "Maximum character length of content (default 5000)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                try ensureEnabled()
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty else {
                    return .init(success: false, output: "Safari is not running.")
                }

                let limit = max(500, min(Int(request.input["limit"] ?? "5000") ?? 5000, 20_000))
                guard let page = BrowserPageReader.current(bundleId: "com.apple.Safari"), !page.isEmpty else {
                    return .init(
                        success: false,
                        output: "Could not read the active Safari page content. Ensure Safari has a page loaded."
                    )
                }

                if let refusal = page.refusal {
                    return .init(success: false, output: refusal.message)
                }

                let cleanText = MarkItDownService.compact(page.text, for: "content extraction", limit: limit)
                var result = "# \(page.title)\nURL: \(page.url)\n\n\(cleanText)"
                if !page.links.isEmpty {
                    let linkList = page.links.prefix(15).map { "- [\($0.text.isEmpty ? $0.url : $0.text)](\($0.url))" }.joined(separator: "\n")
                    result += "\n\n### Page Links:\n\(linkList)"
                }
                return .init(success: true, output: result)
            }
        )
    }

    // MARK: - safari.listTabs

    private static func registerListTabs(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "safari.listTabs",
                title: "List Open Safari Tabs",
                appBundleID: "com.apple.Safari",
                inputSchema: .init(fields: [
                    .init(name: "matching", description: "Optional query to filter by tab title or URL", required: false)
                ]),
                riskLevel: .low
            ) { request in
                try ensureEnabled()
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty else {
                    return .init(success: false, output: "Safari is not running.")
                }

                let tabs = await SafariTabManager.shared.fetchTabs()
                guard !tabs.isEmpty else {
                    return .init(success: true, output: "No tabs open in Safari.")
                }

                let filter = (request.input["matching"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let filtered = filter.isEmpty
                    ? tabs
                    : tabs.filter { $0.title.lowercased().contains(filter) || $0.url.lowercased().contains(filter) }

                guard !filtered.isEmpty else {
                    return .init(success: true, output: "None of the \(tabs.count) open tabs matched '\(filter)'.")
                }

                let lines = filtered.prefix(50).map { tab in
                    "[Win \(tab.windowIndex), Tab \(tab.tabIndex)] \(tab.title.isEmpty ? tab.url : tab.title) — \(tab.url)"
                }
                return .init(
                    success: true,
                    output: "Found \(filtered.count) open Safari tab\(filtered.count == 1 ? "" : "s"):\n" + lines.joined(separator: "\n")
                )
            }
        )
    }

    // MARK: - safari.switchTab

    private static func registerSwitchTab(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "safari.switchTab",
                title: "Switch to Safari Tab",
                appBundleID: "com.apple.Safari",
                inputSchema: .init(fields: [
                    .init(name: "matching", description: "Tab title or URL substring to activate", required: true),
                    .init(name: "windowIndex", description: "Optional window index (1-based)", required: false),
                    .init(name: "tabIndex", description: "Optional tab index within the window (1-based)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                try ensureEnabled()
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty else {
                    return .init(success: false, output: "Safari is not running.")
                }

                let tabs = await SafariTabManager.shared.fetchTabs()
                guard !tabs.isEmpty else {
                    return .init(success: false, output: "No open tabs found in Safari.")
                }

                let matching = (request.input["matching"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let winIdx = request.input["windowIndex"].flatMap(Int.init)
                let tabIdx = request.input["tabIndex"].flatMap(Int.init)

                let targetTab: SafariTab?
                if let winIdx, let tabIdx {
                    targetTab = tabs.first { $0.windowIndex == winIdx && $0.tabIndex == tabIdx }
                } else if !matching.isEmpty {
                    targetTab = tabs.first {
                        $0.title.lowercased().contains(matching) || $0.url.lowercased().contains(matching)
                    }
                } else {
                    targetTab = nil
                }

                guard let target = targetTab else {
                    return .init(success: false, output: "No tab found matching '\(matching)'.")
                }

                SafariTabManager.shared.switchTo(target)

                // Verified read-back: confirm active tab after short delay
                try? await Task.sleep(nanoseconds: 200_000_000)
                let activeRead = BrowserPageReader.current(bundleId: "com.apple.Safari")
                let verified = activeRead?.url == target.url || activeRead?.title == target.title
                let verifyMsg = verified ? " ✓ (Verified active)" : ""

                return .init(
                    success: true,
                    output: "Switched to tab: “\(target.title)” (\(target.url))\(verifyMsg)"
                )
            }
        )
    }
}

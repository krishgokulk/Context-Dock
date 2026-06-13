//
//  AXContextReader.swift
//  ILauncher
//
//  Reads rich live context from the frontmost app using the macOS Accessibility API:
//  selected text, current browser URL, focused window title, focused element role.
//  No extra permissions needed beyond the Accessibility access already required for
//  selected-text detection.
//

import AppKit
import ApplicationServices
import Combine
import Foundation

// MARK: - AXContext ─ value type holding one snapshot of app state

struct AXContext {
    var appName:            String
    var bundleId:           String
    var pid:                pid_t
    var selectedText:       String?
    var currentURL:         String?
    var windowTitle:        String?
    var focusedElementRole: String?   // "AXTextField", "AXWebArea", "AXButton", …
    var selectedFilePaths:  [String] = []  // Finder: currently selected file/folder paths
    var menuItems:          [AXMenuItemInfo] = []
    var timestamp:          Date = Date()

    static let empty = AXContext(appName: "", bundleId: "", pid: 0)

    // MARK: Derived helpers

    var isEmpty: Bool { appName.isEmpty }

    var isInTextField: Bool {
        guard let r = focusedElementRole else { return false }
        return ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(r)
    }

    var isBrowserURL: Bool { currentURL != nil }

    var hasSelection: Bool { !(selectedText ?? "").isEmpty }

    var isBrowser: Bool {
        AXContextReader.browserBundleIds.contains(bundleId)
            || bundleId.hasPrefix("com.apple.Safari")
            || bundleId.lowercased().contains("chrome")
            || bundleId.lowercased().contains("browser")
    }

    // MARK: AI context summary

    var contextSummary: String {
        var parts: [String] = []
        parts.append("Frontmost App: \(appName) (\(bundleId))")
        if let t = windowTitle,  !t.isEmpty { parts.append("Window Title: \(t)") }
        if let u = currentURL,   !u.isEmpty { parts.append("Current URL: \(u)") }
        if let s = selectedText, !s.isEmpty {
            let preview = s.count > 400 ? String(s.prefix(400)) + "…" : s
            parts.append("Selected Text: \(preview)")
        }
        if let r = focusedElementRole, !r.isEmpty { parts.append("Focused Element: \(r)") }
        if !menuItems.isEmpty { parts.append("Menu Items: \(menuItems.count)") }
        return parts.joined(separator: "\n")
    }
}

// Equality ignores menuItems and timestamp — used for diffing to avoid spurious publishes
extension AXContext: Equatable {
    static func == (lhs: AXContext, rhs: AXContext) -> Bool {
        lhs.bundleId          == rhs.bundleId       &&
        lhs.pid               == rhs.pid             &&
        lhs.selectedText      == rhs.selectedText    &&
        lhs.currentURL        == rhs.currentURL      &&
        lhs.windowTitle       == rhs.windowTitle     &&
        lhs.focusedElementRole == rhs.focusedElementRole &&
        lhs.selectedFilePaths == rhs.selectedFilePaths
    }
}

// MARK: - AXContextReader

final class AXContextReader {
    static let shared = AXContextReader()

    // Thread-safe reactive publisher — subscribers receive every distinct context update
    private let _subject = CurrentValueSubject<AXContext, Never>(.empty)
    var contextPublisher: AnyPublisher<AXContext, Never> { _subject.eraseToAnyPublisher() }

    /// Latest snapshot. Safe to read from any thread (CurrentValueSubject is thread-safe).
    private(set) var current: AXContext {
        get { _subject.value }
        set { _subject.send(newValue) }
    }

    static let browserBundleIds: Set<String> = [
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

    private var cancellables = Set<AnyCancellable>()

    private init() {
        subscribeToEventBus()
    }

    // MARK: - Public API

    /// Synchronously snapshots core AX state (no menu enumeration) and publishes if changed.
    /// Menu items are fetched asynchronously and published as a separate update.
    func refresh(from app: NSRunningApplication) {
        let new = buildContext(from: app)
        updateIfChanged(new)
        startAsyncMenuLoad(for: app)
    }

    /// Fast open-path snapshot. No selected text, browser URL, Finder selection, or menu read.
    /// Use when launcher opens so first paint stays cache-only.
    func refreshLightweight(from app: NSRunningApplication) {
        let pid = app.processIdentifier
        let bundleId = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? ""

        var ctx = AXContext(appName: name, bundleId: bundleId, pid: pid)
        let axApp = AXUIElementCreateApplication(pid)
        ctx.windowTitle = readWindowTitle(axApp)
        ctx.focusedElementRole = readFocusedRole(axApp)

        if current.bundleId == bundleId {
            ctx.menuItems = current.menuItems
        }

        updateIfChanged(ctx)
    }

    /// Event-driven entry point — called by AXEventBus subscribers.
    func apply(event: AXEvent) {
        switch event {
        case .appActivated(let app):
            updateApp(app)
        case .focusedElementChanged(let pid), .selectedTextChanged(let pid):
            updateFocusedElement(for: pid)
        case .menuItemsReady(let pid, let items):
            if current.pid == pid {
                var updated = current
                updated.menuItems = items
                updated.timestamp = Date()
                current = updated   // always publish menu updates (menu changes don't affect ==)
            }
        }
    }

    // MARK: - Split updates

    private func updateApp(_ app: NSRunningApplication) {
        let new = buildContext(from: app)
        updateIfChanged(new)
        startAsyncMenuLoad(for: app)
    }

    private func updateFocusedElement(for pid: pid_t) {
        guard current.pid == pid else { return }
        let axApp = AXUIElementCreateApplication(pid)
        var updated = current
        updated.selectedText       = readSelectedText(axApp)
        updated.focusedElementRole = readFocusedRole(axApp)
        updated.windowTitle        = readWindowTitle(axApp)
        updated.timestamp          = Date()
        updateIfChanged(updated)
    }

    private func updateSelectedText(_ text: String, pid: pid_t) {
        guard current.pid == pid else { return }
        var updated = current
        updated.selectedText = text.isEmpty ? nil : text
        updated.timestamp    = Date()
        updateIfChanged(updated)
    }

    // MARK: - Diffing

    private func updateIfChanged(_ new: AXContext) {
        guard new != current else { return }
        current = new
    }

    // MARK: - Context building

    private func buildContext(from app: NSRunningApplication) -> AXContext {
        let pid      = app.processIdentifier
        let bundleId = app.bundleIdentifier ?? ""
        let name     = app.localizedName    ?? ""

        var ctx = AXContext(appName: name, bundleId: bundleId, pid: pid)
        let axApp = AXUIElementCreateApplication(pid)

        ctx.windowTitle        = readWindowTitle(axApp)
        ctx.selectedText       = readSelectedText(axApp)
        ctx.currentURL         = readCurrentURL(axApp, bundleId: bundleId)
        ctx.focusedElementRole = readFocusedRole(axApp)

        if bundleId == "com.apple.finder" {
            ctx.selectedFilePaths = ContextDetector.shared.getFinderSelectedFiles().map { $0.path }
        }

        // Carry forward cached menu items while async reload is in flight
        if current.bundleId == bundleId {
            ctx.menuItems = current.menuItems
        }

        return ctx
    }

    // MARK: - Async menu load

    private func startAsyncMenuLoad(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        Task.detached(priority: .userInitiated) {
            let items = await AXMenuEnumerator.shared.getMenuAsync(for: app)
            await MainActor.run {
                // menuItemsReady bypasses debounce — see subscribeToEventBus
                AXEventBus.shared.emit(.menuItemsReady(pid, items))
            }
        }
    }

    // MARK: - Event bus subscription

    private func subscribeToEventBus() {
        // appActivated and menuItemsReady are latency-sensitive — fire immediately
        AXEventBus.shared.publisher
            .filter {
                switch $0 {
                case .appActivated, .menuItemsReady: return true
                default: return false
                }
            }
            .receive(on: RunLoop.main)
            .sink { [weak self] event in self?.apply(event: event) }
            .store(in: &cancellables)

        // focusedElementChanged and selectedTextChanged fire rapidly — debounce to reduce churn
        AXEventBus.shared.publisher
            .filter {
                switch $0 {
                case .focusedElementChanged, .selectedTextChanged: return true
                default: return false
                }
            }
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] event in self?.apply(event: event) }
            .store(in: &cancellables)
    }

    // MARK: - Window title

    private func readWindowTitle(_ axApp: AXUIElement) -> String? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
           let win = ref {
            let winEl = unsafeBitCast(win, to: AXUIElement.self)
            if let t = strAttr(winEl, kAXTitleAttribute as CFString), !t.isEmpty { return t }
        }
        var wins: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wins) == .success,
           let arr = wins as? [AXUIElement], let first = arr.first {
            return strAttr(first, kAXTitleAttribute as CFString)
        }
        return nil
    }

    // MARK: - Selected text

    private func readSelectedText(_ axApp: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let r = ref else { return nil }
        let el = unsafeBitCast(r, to: AXUIElement.self)

        if let t = strAttr(el, kAXSelectedTextAttribute as CFString), !t.isEmpty { return t }

        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rng = rangeRef {
            var strRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                el, kAXStringForRangeParameterizedAttribute as CFString, rng, &strRef
            ) == .success, let s = strRef as? String, !s.isEmpty {
                return s
            }
        }
        return nil
    }

    // MARK: - Current URL (browsers only)

    private func readCurrentURL(_ axApp: AXUIElement, bundleId: String) -> String? {
        guard Self.browserBundleIds.contains(bundleId)
                || bundleId.hasPrefix("com.apple.Safari")
                || bundleId.lowercased().contains("chrome")
                || bundleId.lowercased().contains("browser")
        else { return nil }

        let depth: Int
        if bundleId == "com.apple.Safari" || bundleId.hasPrefix("com.apple.Safari") {
            depth = 7
        } else if bundleId == "org.mozilla.firefox" {
            depth = 8
        } else {
            depth = 7
        }
        return findAddressBar(axApp, maxDepth: depth)
    }

    private func findAddressBar(_ elem: AXUIElement, maxDepth: Int, depth: Int = 0) -> String? {
        guard depth < maxDepth else { return nil }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        if ["AXTextField", "AXComboBox", "AXSearchField"].contains(role) {
            if let v = strAttr(elem, kAXValueAttribute as CFString), looksLikeURL(v) {
                return v
            }
        }

        var childRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findAddressBar(child, maxDepth: maxDepth, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: - Focused element role

    private func readFocusedRole(_ axApp: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let r = ref else { return nil }
        let el = unsafeBitCast(r, to: AXUIElement.self)
        return strAttr(el, kAXRoleAttribute as CFString)
    }

    // MARK: - Helpers

    private func strAttr(_ el: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success else { return nil }
        return ref as? String
    }

    private func looksLikeURL(_ s: String) -> Bool {
        guard !s.isEmpty, !s.contains(" "), s.count > 4 else { return false }
        let lower = s.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
            || lower.hasPrefix("file://")  || lower.hasPrefix("ftp://")
    }
}

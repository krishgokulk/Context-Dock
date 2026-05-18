// FileContextOverlay.swift
// Context-Dock
//
// Non-activating floating pill that appears next to the mouse cursor (PopClip-style)
// when the user selects file(s) in Finder or text/URL in any app.

import AppKit
import Combine
import SwiftUI


// MARK: - Overlay Context

enum OverlayContext {
    case files([URL])
    case text(String)

    var isEmpty: Bool {
        switch self {
        case .files(let urls): return urls.isEmpty
        case .text(let s):     return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private final class FileContextOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

@MainActor
final class FileContextOverlayController: ObservableObject {
    static let shared = FileContextOverlayController()

    @Published private(set) var context: OverlayContext = .files([])

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var lastShownContextID: String?
    private var textSourceApp: NSRunningApplication?

    // MARK: - Public API

    func update(files: [URL], at mousePoint: NSPoint = NSEvent.mouseLocation) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        let nextContext = OverlayContext.files(files)
        if panel?.isVisible == true, contextIdentity(nextContext) == lastShownContextID {
            return
        }
        show(context: nextContext, near: mousePoint)
    }

    func update(text: String, at mousePoint: NSPoint) {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            hide(animated: true)
            return
        }
        dismissTimer?.invalidate()
        dismissTimer = nil
        textSourceApp = activeContextApp()
        let nextContext = OverlayContext.text(text)
        if panel?.isVisible == true, contextIdentity(nextContext) == lastShownContextID {
            return
        }
        show(context: nextContext, near: mousePoint)
    }

    func updateFromClipboard(at mousePoint: NSPoint = NSEvent.mouseLocation) {
        guard AppSettings.shared.enableFileContextOverlay,
              AppSettings.shared.clipboardAwarePills else {
            hide(animated: true)
            return
        }

        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
           !urls.isEmpty {
            update(files: urls, at: mousePoint)
            return
        }

        guard let text = pasteboard.string(forType: .string) else {
            hide(animated: true)
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            hide(animated: true)
            return
        }

        update(text: trimmed, at: mousePoint)
    }

    func hide(animated: Bool = true) {
        guard panel?.isVisible == true else { return }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                panel?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.panel?.orderOut(nil)
                self?.context = .files([])
                self?.lastShownContextID = nil
            })
        } else {
            panel?.orderOut(nil)
            context = .files([])
            lastShownContextID = nil
            textSourceApp = nil
        }
    }

    // MARK: - File Actions

    func quickLook() {
        guard case .files(let urls) = context, let url = urls.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: src, virtualKey: 0x31, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x31, keyDown: false)?.post(tap: .cghidEventTap)
            _ = url
        }
    }

    func openFiles() {
        guard case .files(let urls) = context else { return }
        urls.forEach { NSWorkspace.shared.open($0) }
        hide()
    }

    func moveToTrash() {
        guard case .files(let urls) = context else { return }
        let count = urls.count
        for url in urls {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        hide()
        let msg = count == 1 ? "Moved to Bin" : "\(count) items moved to Bin"
        AppToast.show(msg, icon: "trash", tint: .red.opacity(0.9))
    }

    func copyPath() {
        guard case .files(let urls) = context else { return }
        let paths = urls.map { $0.path }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
        AppToast.show("Path copied", icon: "link", tint: .white.opacity(0.85))
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func getInfo() {
        guard case .files(let urls) = context else { return }
        let escaped = urls.map { "POSIX file \"\($0.path)\"" }.joined(separator: ", ")
        let script = "tell application \"Finder\" to open information window of {\(escaped)}"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }

    func shareFiles() {
        guard case .files(let urls) = context, !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        let coordinator = SharePickerCoordinator {}
        picker.delegate = coordinator
        objc_setAssociatedObject(
            picker,
            &SharePickerCoordinator.key,
            coordinator,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        guard let panel, let view = panel.contentView else { return }
        let rect = NSRect(x: panel.frame.width - 116, y: 26, width: 88, height: 1)
        picker.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func fileExtensionResults(query: String, files: [URL]) -> [ExtensionDiscoveryResult] {
        guard !files.isEmpty else { return [] }

        let layers: [ExtensionLayer] = [.l2_context, .l1_search]
        var seen = Set<UUID>()
        var results: [ExtensionDiscoveryResult] = []

        for layer in layers {
            let discovered = LayeredExtensionManager.shared.discoverExtensions(
                for: query.trimmingCharacters(in: .whitespacesAndNewlines),
                selectedFiles: files,
                selectedText: nil,
                frontmostApp: "Finder",
                layer: layer
            )
            for result in discovered where seen.insert(result.ilExtension.id).inserted {
                results.append(result)
            }
        }

        return results.sorted { $0.relevanceScore > $1.relevanceScore }
    }

    func finderMenuResults(query: String, limit: Int = 8) -> [AXMenuItem] {
        guard let finder = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.finder"
        }) else {
            return []
        }

        let pid = finder.processIdentifier
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fileActionTitles = [
            "Open", "Open With", "Open in New Tab", "Get Info", "Rename",
            "Compress", "Duplicate", "Make Alias", "Move to Trash", "Move to Bin",
            "Copy", "Share", "Tags", "Quick Look", "Customize Folder",
            "Customise Folder", "Import from iPhone", "Remove Download",
            "Keep Downloaded"
        ]
        let fileActionPaths = ["File", "Services", "Quick Actions", "Open With", "Tags"]
        let thirdPartyServiceHints = [
            "Terminal", "Ghostty", "Downie", "Bluetooth", "TeamViewer",
            "Hammerspoon", "Tuna", "MEGA", "Upload", "Sync", "Backup",
            "Workflow", "Service"
        ]
        let preferredLimit = trimmedQuery.isEmpty ? max(limit, 12) : limit
        let liveItems = AXMenuReader.shared.refreshAllMenuItems(for: pid, maxDepth: 6)
        let items = (liveItems.isEmpty ? AXMenuReader.shared.cachedAllMenuItems(for: pid, maxDepth: 6) : liveItems)
            .filter { $0.isEnabled && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { item -> AXMenuItem in
                var item = item
                item.sourcePID = pid
                item.sourceAppName = "Finder"
                return item
            }
            .filter { item in
                item.path.contains { part in
                    fileActionPaths.contains { part.localizedCaseInsensitiveContains($0) }
                }
                || fileActionTitles.contains { item.title.localizedCaseInsensitiveContains($0) }
                || thirdPartyServiceHints.contains { item.title.localizedCaseInsensitiveContains($0) }
            }

        let matches: [AXMenuItem]
        if trimmedQuery.isEmpty {
            matches = items.filter { item in
                fileActionTitles.contains { needle in
                    item.title.localizedCaseInsensitiveContains(needle)
                        || item.pathString.localizedCaseInsensitiveContains(needle)
                }
                || item.path.contains { part in
                    fileActionPaths.contains { part.localizedCaseInsensitiveContains($0) }
                }
                || thirdPartyServiceHints.contains { hint in
                    item.title.localizedCaseInsensitiveContains(hint)
                }
            }
        } else {
            matches = items.filter { item in
                item.title.lowercased().contains(trimmedQuery)
                    || item.path.contains { $0.lowercased().contains(trimmedQuery) }
            }
        }

        var seen = Set<String>()
        let deduped = matches.filter { item in
            seen.insert(item.pathString.lowercased()).inserted
        }

        let ordered = deduped.sorted {
            func priority(_ item: AXMenuItem) -> Int {
                let title = item.title.lowercased()
                let pathString = item.pathString.lowercased()
                if !trimmedQuery.isEmpty {
                    if title == trimmedQuery { return 0 }
                    if title.hasPrefix(trimmedQuery) { return 1 }
                    if pathString.contains(trimmedQuery) { return 2 }
                }
                if title == "open" { return 10 }
                if title.contains("open with") { return 11 }
                if title.contains("open in new tab") { return 12 }
                if title.contains("move to bin") || title.contains("move to trash") { return 20 }
                if title.contains("get info") { return 21 }
                if title.contains("rename") { return 22 }
                if title.contains("compress") { return 23 }
                if title.contains("duplicate") { return 24 }
                if title.contains("make alias") { return 25 }
                if title.contains("quick look") { return 26 }
                if title == "copy" { return 30 }
                if title.contains("share") { return 31 }
                if title.contains("tag") { return 32 }
                if title.contains("quick action") || pathString.contains("quick actions") { return 40 }
                if title.contains("service") || pathString.contains("services") { return 41 }
                return 90 + item.path.count
            }

            let aPriority = priority($0)
            let bPriority = priority($1)
            if aPriority != bPriority { return aPriority < bPriority }
            return $0.path.count < $1.path.count
        }

        return Array(ordered.prefix(preferredLimit))
    }

    func activeAppMenuResults(query: String, limit: Int = 8) -> [AXMenuItem] {
        guard let app = textSourceApp ?? activeContextApp() else { return [] }
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "App"
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items = AXMenuReader.shared.cachedAllMenuItems(for: pid, maxDepth: 6)
            .filter { $0.isEnabled && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { item -> AXMenuItem in
                var item = item
                item.sourcePID = pid
                item.sourceAppName = appName
                return item
            }

        let matches: [AXMenuItem]
        if trimmedQuery.isEmpty {
            let preferred = [
                "Copy", "Cut", "Paste", "Share", "Look Up", "Speech",
                "Translate", "Format", "Refactor", "Explain", "Review",
                "Add Selection", "Ask", "Command Palette"
            ]
            matches = items.filter { item in
                preferred.contains { needle in
                    item.title.localizedCaseInsensitiveContains(needle)
                        || item.pathString.localizedCaseInsensitiveContains(needle)
                }
            }
        } else {
            matches = items.filter { item in
                item.title.lowercased().contains(trimmedQuery)
                    || item.path.contains { $0.lowercased().contains(trimmedQuery) }
            }
        }

        var seen = Set<String>()
        let deduped = matches.filter { item in
            seen.insert(item.pathString.lowercased()).inserted
        }

        return Array(deduped.sorted {
            let aTitle = trimmedQuery.isEmpty || $0.title.lowercased().contains(trimmedQuery) ? 0 : 1
            let bTitle = trimmedQuery.isEmpty || $1.title.lowercased().contains(trimmedQuery) ? 0 : 1
            if aTitle != bTitle { return aTitle < bTitle }
            return $0.path.count < $1.path.count
        }.prefix(limit))
    }

    func textExtensionResults(query: String, selectedText: String) -> [ExtensionDiscoveryResult] {
        let trimmedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelection.isEmpty else { return [] }
        let appName = (textSourceApp ?? activeContextApp())?.localizedName
        let layers: [ExtensionLayer] = [.l2_context, .l1_search]
        var seen = Set<UUID>()
        var results: [ExtensionDiscoveryResult] = []

        for layer in layers {
            let discovered = LayeredExtensionManager.shared.discoverExtensions(
                for: query.trimmingCharacters(in: .whitespacesAndNewlines),
                selectedFiles: [],
                selectedText: trimmedSelection,
                frontmostApp: appName,
                layer: layer
            )
            for result in discovered where seen.insert(result.ilExtension.id).inserted {
                results.append(result)
            }
        }

        return results.sorted { $0.relevanceScore > $1.relevanceScore }
    }

    func submitFilePrompt(_ prompt: String, files: [URL]) {
        let results = fileExtensionResults(query: prompt, files: files)
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let top = results.first {
            runExtension(top.ilExtension, files: files)
        } else if !trimmed.isEmpty, let menuItem = finderMenuResults(query: prompt, limit: 1).first {
            runMenuItem(menuItem)
        } else {
            askAboutFiles(prompt: prompt)
        }
    }

    func runExtension(_ ext: ILExtension, files: [URL]) {
        guard !files.isEmpty else { return }
        Task {
            do {
                let output = try await LayeredExtensionManager.shared.execute(extension: ext, with: files)
                await MainActor.run {
                    let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    AppToast.show(
                        message.isEmpty ? "\(ext.name) finished" : message,
                        icon: ext.icon,
                        tint: .white.opacity(0.85)
                    )
                    self.hide()
                }
            } catch {
                await MainActor.run {
                    AppToast.show(
                        "\(ext.name) failed",
                        icon: "exclamationmark.triangle",
                        tint: .red.opacity(0.9)
                    )
                }
            }
        }
    }

    func runMenuItem(_ item: AXMenuItem) {
        let pid = item.sourcePID
        let path = item.path
        let shortcutChar = item.shortcutChar
        let shortcutModifiers = item.shortcutModifiers
        guard pid != 0, !path.isEmpty else { return }

        Task.detached(priority: .userInitiated) {
            if let shortcutChar, !shortcutChar.isEmpty {
                await AXMenuReader.shared.executeShortcut(
                    char: shortcutChar,
                    modifiers: shortcutModifiers,
                    in: pid
                )
            } else {
                _ = await AXMenuReader.shared.clickMenuItem(path: path, in: pid)
            }
            await MainActor.run { self.hide() }
        }
    }

    func submitTextPrompt(_ prompt: String, selectedText: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let menuItem = activeAppMenuResults(query: trimmed, limit: 1).first {
            runMenuItem(menuItem)
        } else {
            askAboutText(selectedText, prompt: trimmed)
        }
    }

    // MARK: - Text Actions

    func copySelection() {
        guard case .text(let text) = context else { return }
        copyText(text)
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        AppToast.show("Copied", icon: "doc.on.doc", tint: .white.opacity(0.85))
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func askAboutSelection() {
        guard case .text(let text) = context else { return }
        askAboutText(text)
    }

    func askAboutText(_ text: String) {
        askAboutText(text, prompt: "")
    }

    func askAboutText(_ text: String, prompt: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = trimmedPrompt.isEmpty
            ? trimmed
            : "\(trimmedPrompt)\n\nSelected text:\n\(trimmed)"
        NotificationCenter.default.post(
            name: .overlayAskAboutSelection,
            object: nil,
            userInfo: ["text": payload]
        )
        hide()
    }

    func askAboutFiles(prompt: String) {
        guard case .files(let urls) = context, !urls.isEmpty else { return }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = urls.map(\.path).joined(separator: "\n")
        let text = trimmedPrompt.isEmpty
            ? "Use these selected files:\n\(paths)"
            : "\(trimmedPrompt)\n\nSelected files:\n\(paths)"
        askAboutText(text)
    }

    func searchSelection() {
        guard case .text(let text) = context else { return }
        searchText(text)
    }

    func searchText(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
        hide()
    }

    func lookUpInDictionary() {
        guard case .text(let text) = context else { return }
        lookUpText(text)
    }

    func lookUpText(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let word = text.components(separatedBy: .whitespacesAndNewlines).first ?? text
        if let url = URL(string: "dict://\(word)") { NSWorkspace.shared.open(url) }
        hide()
    }

    func openURL() {
        guard case .text(let text) = context else { return }
        openURL(text)
    }

    func openURL(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: t), url.scheme != nil { NSWorkspace.shared.open(url) }
        hide()
    }

    func focusInputPanel() {
        panel?.makeKey()
    }

    // MARK: - Private

    private func activeContextApp() -> NSRunningApplication? {
        let selfBundleID = Bundle.main.bundleIdentifier
        if let previous = AppDelegate.shared?.previousFrontmostApp,
           previous.bundleIdentifier != selfBundleID,
           !previous.isTerminated {
            return previous
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != selfBundleID {
            return front
        }
        return nil
    }

    private func show(context: OverlayContext, near mousePoint: NSPoint) {
        if context.isEmpty {
            hide(animated: true)
            return
        }
        let nextContextID = contextIdentity(context)
        if panel?.isVisible == true, nextContextID == lastShownContextID {
            return
        }

        self.context = context
        lastShownContextID = nextContextID
        let pillW = pillWidth(for: context)

        if panel == nil { buildPanel(width: pillW) } else { updatePanelWidth(pillW) }
        positionNearMouse(mousePoint, width: pillW)

        if panel?.isVisible == false {
            panel?.alphaValue = 0
            panel?.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel?.animator().alphaValue = 1
            }
        }
    }

    private func pillWidth(for ctx: OverlayContext) -> CGFloat {
        switch ctx {
        case .files: return 160
        case .text: return 320
        }
    }

    private func contextIdentity(_ context: OverlayContext) -> String {
        switch context {
        case .files(let urls):
            return "files:" + urls.map(\.path).sorted().joined(separator: "\n")
        case .text(let text):
            return "text:" + text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var pillHeight: CGFloat { 40 }

    private func buildPanel(width: CGFloat) {
        let panel = FileContextOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: pillHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: FileContextPillView().environmentObject(self))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
    }

    private func updatePanelWidth(_ width: CGFloat) {
        resizePanel(width: width, height: pillHeight)
    }

    func resizePanel(width: CGFloat, height: CGFloat) {
        guard let panel else { return }
        var f = panel.frame
        let oldWidth = f.width
        let oldHeight = f.height
        f.size.width = width
        f.size.height = height
        f.origin.x -= (width - oldWidth) / 2
        f.origin.y += oldHeight - height

        if let screen = panel.screen ?? NSScreen.main {
            let sf = screen.visibleFrame
            f.origin.x = max(sf.minX + 8, min(f.origin.x, sf.maxX - width - 8))
            f.origin.y = max(sf.minY + 8, min(f.origin.y, sf.maxY - height - 8))
        }

        panel.setFrame(f, display: false)
    }

    /// Position the pill just above the mouse cursor, clamped to screen bounds.
    private func positionNearMouse(_ point: NSPoint, width: CGFloat) {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }

        let sf = screen.visibleFrame
        let pillH = panel.frame.height
        let gap: CGFloat = 18   // distance above cursor

        var x = point.x - width / 2
        var y = point.y + gap

        // Clamp horizontally
        x = max(sf.minX + 8, min(x, sf.maxX - width - 8))

        // If pill would go above the visible area, flip below cursor
        if y + pillH > sf.maxY - 8 {
            y = point.y - pillH - gap
        }

        // Never clip below visible area
        y = max(sf.minY + 8, y)

        panel.setFrame(NSRect(x: x, y: y, width: width, height: pillH), display: false)
    }
}

// MARK: - Text Selection Monitor

@MainActor
final class TextSelectionMonitor {
    /// Called with (selectedText, mouseLocationAtMouseUp)
    var onChange: ((String, NSPoint) -> Void)?

    private var mouseMonitor: Any?
    private var currentPid: pid_t = 0
    private var debounceTask: Task<Void, Never>?
    private var capturedMouseLocation: NSPoint = .zero

    func start(for pid: pid_t) {
        currentPid = pid
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            // Capture mouse location immediately (before debounce moves it)
            self?.capturedMouseLocation = NSEvent.mouseLocation
            self?.scheduleCheck()
        }
    }

    func updatePid(_ pid: pid_t) {
        currentPid = pid
    }

    func stop() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        debounceTask?.cancel()
        currentPid = 0
    }

    private func scheduleCheck() {
        debounceTask?.cancel()
        let pid = currentPid
        let loc = capturedMouseLocation
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000) // 180 ms
            guard !Task.isCancelled, let self else { return }
            let text = Self.readSelectedText(from: pid) ?? ""
            self.onChange?(text, loc)
        }
    }

    static func readSelectedText(from pid: pid_t) -> String? {
        guard pid != 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &textRef) == .success,
              let text = textRef as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

// MARK: - Pill View

struct FileContextPillView: View {
    @EnvironmentObject var ctrl: FileContextOverlayController

    var body: some View {
        switch ctrl.context {
        case .files(let urls):
            FilePillContent(urls: urls)
                .environmentObject(ctrl)
        case .text(let text):
            TextPillContent(text: text)
                .environmentObject(ctrl)
        }
    }

    private var pillBackground: some View {
        ZStack {
            PillBlurView()
            Color.white.opacity(0.06)
            Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1)
        }
    }
}

// MARK: - File Pill Content

private struct FilePillContent: View {
    @EnvironmentObject var ctrl: FileContextOverlayController
    let urls: [URL]
    @State private var prompt: String = ""
    @State private var isPromptHovering = false
    @State private var isActionsExpanded = false
    @FocusState private var isPromptFocused: Bool

    private var extensionResults: [ExtensionDiscoveryResult] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return Array(ctrl.fileExtensionResults(query: trimmed, files: urls).prefix(8))
    }

    private var menuResults: [AXMenuItem] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return ctrl.finderMenuResults(query: trimmed, limit: trimmed.isEmpty ? 12 : 8)
    }

    private var promptIsExpanded: Bool {
        isPromptHovering || isPromptFocused || isActionsExpanded || !prompt.isEmpty
    }

    private var pillWidth: CGFloat {
        promptIsExpanded ? 252 : 160
    }

    private var panelHeight: CGFloat {
        isActionsExpanded ? 40 + 8 + actionsPanelHeight : 40
    }

    private var actionsPanelHeight: CGFloat {
        min(CGFloat(actionCount) * 34 + 16, 340)
    }

    private var actionCount: Int {
        min(extensionResults.count + menuResults.count + 4, 14)
    }

    var body: some View {
        VStack(spacing: 8) {
            pillRow

            if isActionsExpanded {
                actionsPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: pillWidth, height: panelHeight, alignment: .top)
        .animation(.spring(response: 0.2, dampingFraction: 0.86), value: promptIsExpanded)
        .animation(.spring(response: 0.2, dampingFraction: 0.86), value: isActionsExpanded)
        .onAppear { syncPanelSize() }
        .onHover { hovering in
            if !hovering {
                collapseInputAndActions()
            }
        }
        .onChange(of: promptIsExpanded) { _, _ in syncPanelSize() }
        .onChange(of: isActionsExpanded) { _, _ in syncPanelSize() }
    }

    private var pillRow: some View {
        HStack(spacing: 5) {
            promptControl

            Spacer(minLength: 0)
            inlineButton("doc.on.clipboard", "Copy Path") { ctrl.copyPath() }
            inlineButton("square.and.arrow.up", "Share") { ctrl.shareFiles() }
            inlineButton("info.circle", "Get Info") { ctrl.getInfo() }
            ellipsisButton
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(width: pillWidth, height: 40)
        .background(pillBackground)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
    }

    private var pillBackground: some View {
        ZStack {
            PillBlurView()
            Color.white.opacity(0.06)
            Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1)
        }
    }

    private var promptControl: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.68))
                .frame(width: 18, height: 28)

            if promptIsExpanded {
                TextField("Ask...", text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .focused($isPromptFocused)
                    .onSubmit { ctrl.submitFilePrompt(prompt, files: urls) }
                    .frame(width: 84)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .frame(width: promptIsExpanded ? 108 : 24, height: 28, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                isPromptHovering = hovering
            }
        }
        .onTapGesture {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                isPromptHovering = true
            }
            ctrl.focusInputPanel()
            DispatchQueue.main.async {
                isPromptFocused = true
            }
        }
        .help("Type a file action, like zip or compress")
        .animation(.spring(response: 0.18, dampingFraction: 0.85), value: promptIsExpanded)
    }

    private var ellipsisButton: some View {
        Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.86)) {
                let nextExpanded = !isActionsExpanded
                isActionsExpanded = nextExpanded
                if nextExpanded {
                    ctrl.focusInputPanel()
                    DispatchQueue.main.async {
                        isPromptFocused = true
                    }
                } else if prompt.isEmpty {
                    isPromptFocused = false
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show file actions")
    }

    private var actionsPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if !extensionResults.isEmpty {
                    ForEach(extensionResults.prefix(4), id: \.ilExtension.id) { result in
                        actionRow(icon: result.ilExtension.icon, title: result.ilExtension.name) {
                            ctrl.runExtension(result.ilExtension, files: urls)
                        }
                    }
                    Divider().opacity(0.25).padding(.horizontal, 12)
                }

                if !menuResults.isEmpty {
                    ForEach(menuResults.prefix(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 10 : 8), id: \.id) { item in
                        actionRow(
                            icon: "menubar.rectangle",
                            title: item.title,
                            detail: item.path.dropLast().last ?? "Finder"
                        ) {
                            ctrl.runMenuItem(item)
                        }
                    }
                    Divider().opacity(0.25).padding(.horizontal, 12)
                }

                actionRow(icon: "sparkles", title: "Ask AI") {
                    ctrl.askAboutFiles(prompt: prompt)
                }
                actionRow(icon: "eye", title: "Quick Look") {
                    ctrl.quickLook()
                }
                actionRow(icon: "arrow.up.right.square", title: "Open") {
                    ctrl.openFiles()
                }
                actionRow(icon: "trash", title: "Move to Bin", tint: .red.opacity(0.85)) {
                    ctrl.moveToTrash()
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: pillWidth, height: actionsPanelHeight)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 8)
    }

    private var panelBackground: some View {
        ZStack {
            PillBlurView()
            Color.black.opacity(0.12)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func inlineButton(_ icon: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.74))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    @ViewBuilder
    private func actionRow(
        icon: String,
        title: String,
        detail: String? = nil,
        tint: Color = .white.opacity(0.78),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func syncPanelSize() {
        ctrl.resizePanel(width: pillWidth, height: panelHeight)
    }

    private func collapseInputAndActions() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.86)) {
            isActionsExpanded = false
            isPromptHovering = false
            if prompt.isEmpty {
                isPromptFocused = false
            }
        }
    }
}

// MARK: - Text / URL Pill Content

private struct TextPillContent: View {
    @EnvironmentObject var ctrl: FileContextOverlayController
    let text: String
    @State private var selectedText: String
    @State private var prompt: String = ""
    @State private var isPromptHovering = false
    @State private var isActionsExpanded = false
    @FocusState private var isPromptFocused: Bool

    init(text: String) {
        self.text = text
        _selectedText = State(initialValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var trimmedSelection: String {
        selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isURL: Bool {
        let t = trimmedSelection
        guard let url = URL(string: t) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    private var extensionResults: [ExtensionDiscoveryResult] {
        Array(ctrl.textExtensionResults(query: prompt, selectedText: selectedText).prefix(4))
    }

    private var menuResults: [AXMenuItem] {
        ctrl.activeAppMenuResults(query: prompt, limit: 8)
    }

    private var promptIsExpanded: Bool {
        isPromptHovering || isPromptFocused || isActionsExpanded || !prompt.isEmpty
    }

    private var pillWidth: CGFloat {
        promptIsExpanded ? 252 : 160
    }

    private var panelHeight: CGFloat {
        isActionsExpanded ? 40 + 8 + actionsPanelHeight : 40
    }

    private var actionsPanelHeight: CGFloat {
        min(CGFloat(actionCount) * 34 + 16, 238)
    }

    private var actionCount: Int {
        min(extensionResults.count + menuResults.count + 4, 9)
    }

    var body: some View {
        VStack(spacing: 8) {
            pillRow

            if isActionsExpanded {
                actionsPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: pillWidth, height: panelHeight, alignment: .top)
        .animation(.spring(response: 0.2, dampingFraction: 0.86), value: promptIsExpanded)
        .animation(.spring(response: 0.2, dampingFraction: 0.86), value: isActionsExpanded)
        .onAppear { syncPanelSize() }
        .onHover { hovering in
            if !hovering {
                collapseInputAndActions()
            }
        }
        .onChange(of: promptIsExpanded) { _, _ in syncPanelSize() }
        .onChange(of: isActionsExpanded) { _, _ in syncPanelSize() }
        .onChange(of: text) { _, newValue in
            selectedText = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            prompt = ""
            isActionsExpanded = false
            isPromptFocused = false
        }
    }

    private var pillRow: some View {
        HStack(spacing: 5) {
            promptControl

            Spacer(minLength: 0)
            inlineButton("doc.on.doc", "Copy") { ctrl.copyText(trimmedSelection) }
            inlineButton(isURL ? "arrow.up.right.square" : "magnifyingglass", isURL ? "Open URL" : "Search") {
                if isURL {
                    ctrl.openURL(trimmedSelection)
                } else {
                    ctrl.searchText(trimmedSelection)
                }
            }
            inlineButton("text.magnifyingglass", "Look Up") { ctrl.lookUpText(trimmedSelection) }
            ellipsisButton
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(width: pillWidth, height: 40)
        .background(pillBackground)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
    }

    private var promptControl: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.68))
                .frame(width: 18, height: 28)

            if promptIsExpanded {
                TextField("Ask...", text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .focused($isPromptFocused)
                    .onSubmit { ctrl.submitTextPrompt(prompt, selectedText: selectedText) }
                    .frame(width: 84)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .frame(width: promptIsExpanded ? 108 : 24, height: 28, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                isPromptHovering = hovering
            }
        }
        .onTapGesture {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                isPromptHovering = true
            }
            ctrl.focusInputPanel()
            DispatchQueue.main.async {
                isPromptFocused = true
            }
        }
        .help("Type a text action, like translate or explain")
        .animation(.spring(response: 0.18, dampingFraction: 0.85), value: promptIsExpanded)
    }

    private var ellipsisButton: some View {
        Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.86)) {
                isActionsExpanded.toggle()
                if isActionsExpanded {
                    ctrl.focusInputPanel()
                    DispatchQueue.main.async {
                        isPromptFocused = true
                    }
                } else if prompt.isEmpty {
                    isPromptFocused = false
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show text actions")
    }

    private var actionsPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if !extensionResults.isEmpty {
                    ForEach(extensionResults.prefix(3), id: \.ilExtension.id) { result in
                        actionRow(icon: result.ilExtension.icon, title: result.ilExtension.name) {
                            ctrl.askAboutText(selectedText, prompt: result.ilExtension.name)
                        }
                    }
                    Divider().opacity(0.25).padding(.horizontal, 12)
                }

                if !menuResults.isEmpty {
                    ForEach(menuResults.prefix(5), id: \.id) { item in
                        actionRow(
                            icon: "menubar.rectangle",
                            title: item.title,
                            detail: item.path.dropLast().last ?? item.sourceAppName
                        ) {
                            ctrl.runMenuItem(item)
                        }
                    }
                    Divider().opacity(0.25).padding(.horizontal, 12)
                }

                actionRow(icon: "sparkles", title: "Ask AI") {
                    ctrl.askAboutText(selectedText, prompt: prompt)
                }
                actionRow(icon: "doc.on.doc", title: "Copy") {
                    ctrl.copyText(trimmedSelection)
                }
                actionRow(icon: "magnifyingglass", title: "Search Web") {
                    ctrl.searchText(trimmedSelection)
                }
                actionRow(icon: "text.magnifyingglass", title: "Dictionary") {
                    ctrl.lookUpText(trimmedSelection)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: pillWidth, height: actionsPanelHeight)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 8)
    }

    private var pillBackground: some View {
        ZStack {
            PillBlurView()
            Color.white.opacity(0.06)
            Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1)
        }
    }

    private var panelBackground: some View {
        ZStack {
            PillBlurView()
            Color.black.opacity(0.12)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func inlineButton(_ icon: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.74))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    @ViewBuilder
    private func actionRow(
        icon: String,
        title: String,
        detail: String? = nil,
        tint: Color = .white.opacity(0.78),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func syncPanelSize() {
        ctrl.resizePanel(width: pillWidth, height: panelHeight)
    }

    private func collapseInputAndActions() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.86)) {
            isActionsExpanded = false
            isPromptHovering = false
            if prompt.isEmpty {
                isPromptFocused = false
            }
        }
    }
}

// MARK: - Blur background (NSViewRepresentable)

private struct PillBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

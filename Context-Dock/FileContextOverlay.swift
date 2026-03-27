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

// MARK: - Notification

extension NSNotification.Name {
    static let overlayAskAboutSelection = NSNotification.Name("ContextDockAskAboutSelection")
}

// MARK: - Controller

@MainActor
final class FileContextOverlayController: ObservableObject {
    static let shared = FileContextOverlayController()

    @Published private(set) var context: OverlayContext = .files([])

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    // MARK: - Public API

    func update(files: [URL], at mousePoint: NSPoint = NSEvent.mouseLocation) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        show(context: .files(files), near: mousePoint)
    }

    func update(text: String, at mousePoint: NSPoint) {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            hide(animated: true)
            return
        }
        dismissTimer?.invalidate()
        dismissTimer = nil
        show(context: .text(text), near: mousePoint)
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
            })
        } else {
            panel?.orderOut(nil)
            context = .files([])
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

    // MARK: - Text Actions

    func copySelection() {
        guard case .text(let text) = context else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        AppToast.show("Copied", icon: "doc.on.doc", tint: .white.opacity(0.85))
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func askAboutSelection() {
        guard case .text(let text) = context else { return }
        NotificationCenter.default.post(
            name: .overlayAskAboutSelection,
            object: nil,
            userInfo: ["text": text]
        )
        hide()
    }

    func searchSelection() {
        guard case .text(let text) = context else { return }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
        hide()
    }

    func lookUpInDictionary() {
        guard case .text(let text) = context else { return }
        let word = text.components(separatedBy: .whitespacesAndNewlines).first ?? text
        if let url = URL(string: "dict://\(word)") { NSWorkspace.shared.open(url) }
        hide()
    }

    func openURL() {
        guard case .text(let text) = context else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: t), url.scheme != nil { NSWorkspace.shared.open(url) }
        hide()
    }

    // MARK: - Private

    private func show(context: OverlayContext, near mousePoint: NSPoint) {
        if context.isEmpty {
            hide(animated: true)
            return
        }
        self.context = context
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
        case .files: return 380
        case .text(let s):
            // URL mode needs slightly less room (3 buttons)
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let isURL = (URL(string: t)?.scheme == "http" || URL(string: t)?.scheme == "https")
            return isURL ? 360 : 420
        }
    }

    private func buildPanel(width: CGFloat) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 52),
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
        guard let panel else { return }
        var f = panel.frame
        f.size.width = width
        panel.setFrame(f, display: false)
    }

    /// Position the pill just above the mouse cursor, clamped to screen bounds.
    private func positionNearMouse(_ point: NSPoint, width: CGFloat) {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }

        let sf = screen.visibleFrame
        let pillH: CGFloat = 52
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
        Group {
            switch ctrl.context {
            case .files(let urls): FilePillContent(urls: urls)
            case .text(let text):  TextPillContent(text: text)
            }
        }
        .environmentObject(ctrl)
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
}

// MARK: - File Pill Content

private struct FilePillContent: View {
    @EnvironmentObject var ctrl: FileContextOverlayController
    let urls: [URL]

    private var primary: URL? { urls.first }
    private var label: String {
        urls.count == 1 ? (primary?.lastPathComponent ?? "") : "\(urls.count) items"
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let url = primary {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().interpolation(.high)
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: "doc").font(.system(size: 18))
                }
            }
            .padding(.leading, 14)

            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.middle)
                .padding(.leading, 8)
                .frame(maxWidth: 110, alignment: .leading)

            pillDivider

            HStack(spacing: 1) {
                pillBtn("eye",                   "Quick Look")  { ctrl.quickLook() }
                pillBtn("arrow.up.right.square", "Open")        { ctrl.openFiles() }
                pillBtn("link",                  "Copy Path")   { ctrl.copyPath() }
                pillBtn("info.circle",           "Get Info")    { ctrl.getInfo() }
                pillBtn("trash", "Move to Bin", tint: .red.opacity(0.85)) { ctrl.moveToTrash() }
            }
            .padding(.trailing, 8)
        }
        .frame(width: 380, height: 52)
    }

    private var pillDivider: some View {
        Rectangle().fill(.white.opacity(0.12))
            .frame(width: 1, height: 26).padding(.horizontal, 10)
    }

    @ViewBuilder
    private func pillBtn(_ icon: String, _ tip: String,
                         tint: Color = .white.opacity(0.78),
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).help(tip)
    }
}

// MARK: - Text / URL Pill Content

private struct TextPillContent: View {
    @EnvironmentObject var ctrl: FileContextOverlayController
    let text: String

    private var isURL: Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    private var snippet: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 26 ? String(t.prefix(26)) + "…" : t
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: isURL ? "link" : "text.cursor")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isURL ? Color.blue.opacity(0.9) : Color.white.opacity(0.65))
                .frame(width: 26, height: 26)
                .padding(.leading, 14)

            Text(snippet)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.tail)
                .padding(.leading, 8)
                .frame(maxWidth: 120, alignment: .leading)

            Rectangle().fill(.white.opacity(0.12))
                .frame(width: 1, height: 26).padding(.horizontal, 10)

            HStack(spacing: 1) {
                if isURL {
                    pillBtn("safari",     "Open in Browser") { ctrl.openURL() }
                    pillBtn("doc.on.doc", "Copy URL")        { ctrl.copySelection() }
                    pillBtn("sparkles",   "Ask AI")          { ctrl.askAboutSelection() }
                } else {
                    pillBtn("doc.on.doc",            "Copy")           { ctrl.copySelection() }
                    pillBtn("sparkles",              "Ask About This") { ctrl.askAboutSelection() }
                    pillBtn("magnifyingglass",       "Search Web")     { ctrl.searchSelection() }
                    pillBtn("character.book.closed", "Dictionary")     { ctrl.lookUpInDictionary() }
                }
            }
            .padding(.trailing, 8)
        }
        .frame(width: isURL ? 360 : 420, height: 52)
    }

    @ViewBuilder
    private func pillBtn(_ icon: String, _ tip: String,
                         tint: Color = .white.opacity(0.78),
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).help(tip)
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

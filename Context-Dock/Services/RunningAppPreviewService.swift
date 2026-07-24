import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

struct RunningAppWindowPreview: Identifiable {
    let id: CGWindowID
    let title: String
    let bounds: CGRect
    let image: CGImage?
    var minimized: Bool = false
}

struct WindowReviewGroup: Identifiable {
    let id: pid_t
    let app: NSRunningApplication
    let name: String
    let icon: NSImage?
    var windows: [RunningAppWindowPreview]
}

@MainActor
final class RunningAppPreviewService: ObservableObject {
    static let shared = RunningAppPreviewService()

    @Published private(set) var appName: String = ""
    @Published private(set) var previews: [RunningAppWindowPreview] = []
    @Published private(set) var appIcon: NSImage?
    @Published private(set) var reviewGroups: [WindowReviewGroup] = []

    private var panel: NSPanel?
    private var hoverTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var activePID: pid_t = 0
    private var cache: [pid_t: (date: Date, previews: [RunningAppWindowPreview])] = [:]

    private init() {}

    func scheduleShow(for app: NSRunningApplication, icon: NSImage? = nil) {
        hoverTask?.cancel()
        hideTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.show(for: app, icon: icon)
            }
        }
    }

    /// Keyboard entry point for the same per-app window switcher used by capsule hover.
    /// It deliberately stays app-scoped: this does not enter or mutate any dock/chat mode.
    func showWindowReview() {
        let app = AppDelegate.shared?.menuBarOwningUserFacingApplication()
            ?? AppDelegate.shared?.previousFrontmostApp
        guard let app, !app.isTerminated else { return }
        hoverTask?.cancel()
        hideTask?.cancel()
        show(for: app, icon: app.icon)
    }

    func loadWindowReview() {
        let ownBundleID = Bundle.main.bundleIdentifier
        reviewGroups = NSWorkspace.shared.runningApplications
            .filter {
                !$0.isTerminated && $0.activationPolicy == .regular
                    && $0.bundleIdentifier != ownBundleID
            }
            .compactMap { app in
                let windows = windowPreviews(for: app)
                guard !windows.isEmpty else { return nil }
                return WindowReviewGroup(
                    id: app.processIdentifier, app: app, name: app.localizedName ?? "App",
                    icon: app.icon, windows: windows)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for group in reviewGroups {
            refreshReviewScreenshots(for: group.app, previews: group.windows)
        }
    }

    func focus(_ preview: RunningAppWindowPreview, in app: NSRunningApplication) {
        activePID = app.processIdentifier
        focus(preview)
    }

    func scheduleHide() {
        hoverTask?.cancel()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            // Leave enough time to cross the small gap between the capsule and preview.
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.hide()
            }
        }
    }

    func keepVisible() {
        hideTask?.cancel()
    }

    func hide() {
        hoverTask?.cancel()
        hideTask?.cancel()
        panel?.orderOut(nil)
        activePID = 0
    }

    func focus(_ preview: RunningAppWindowPreview) {
        guard activePID > 0 else { return }
        let app = NSRunningApplication(processIdentifier: activePID)
        if app?.isHidden == true { app?.unhide() }
        app?.activate(options: [.activateIgnoringOtherApps])

        guard MenuExecutionCoordinator.ensureAccessibilityTrustOrPrompt() else {
            hide()
            return
        }
        let axApp = AXUIElementCreateApplication(activePID)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
            == .success,
            let windows = windowsRef as? [AXUIElement]
        else {
            hide()
            return
        }

        let target = bestAXWindowMatch(for: preview, in: windows) ?? windows.first
        if let target {
            // Un-minimize first so clicking a minimized preview restores its window.
            AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        }
        hide()
    }

    private func show(for app: NSRunningApplication, icon: NSImage?) {
        guard !app.isTerminated else { return }
        let pid = app.processIdentifier
        var windows = windowPreviews(for: app)
        if windows.isEmpty {
            // Always acknowledge hover. Apps with no ordinary windows, or Macs where
            // Accessibility/Screen Recording is unavailable, still get an actionable card.
            windows = [RunningAppWindowPreview(
                id: CGWindowID(0xFFFF_FFFE),
                title: app.localizedName ?? "App",
                bounds: .zero,
                image: nil
            )]
        }

        activePID = pid
        appName = app.localizedName ?? "App"
        appIcon = icon ?? app.icon
        previews = windows
        if panel == nil { buildPanel() }
        sizeAndPositionPanel(itemCount: windows.count)
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }
        refreshScreenshots(for: app, previews: windows)
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 230),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        let root = RunningAppPreviewPanelView(service: self)
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
    }

    private func sizeAndPositionPanel(itemCount: Int) {
        guard let panel else { return }
        let count = min(max(itemCount, 1), 5)
        let itemWidth: CGFloat = 184
        let width = min(CGFloat(count) * itemWidth + 52, 980)
        let height: CGFloat = 246
        panel.setContentSize(NSSize(width: width, height: height))

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        let x = min(max(mouse.x - width / 2, visible.minX + 18), visible.maxX - width - 18)

        // Prefer showing ABOVE the hovered capsule icon (snapshot grows upward, clear of
        // the result sheet). Fall back below only when there isn't room above, so it
        // never renders off-screen / empty.
        let gap: CGFloat = 12
        let aboveY = mouse.y + gap
        let belowY = mouse.y - gap - height
        let y: CGFloat
        if aboveY + height <= visible.maxY - 10 {
            y = aboveY
        } else if belowY >= visible.minY + 10 {
            y = belowY
        } else {
            y = min(max(aboveY, visible.minY + 10), visible.maxY - 10 - height)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func windowPreviews(for app: NSRunningApplication) -> [RunningAppWindowPreview] {
        let pid = app.processIdentifier
        if let cached = cache[pid], Date().timeIntervalSince(cached.date) < 0.85 {
            return cached.previews
        }

        // `.optionAll` is required for minimized windows and windows on another Space.
        // Filtering by owner, layer, alpha, and useful bounds below removes helper surfaces.
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let result = infoList.compactMap { info -> RunningAppWindowPreview? in
            guard
                let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                ownerPID.int32Value == pid,
                let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                let layer = info[kCGWindowLayer as String] as? NSNumber,
                layer.intValue == 0,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                bounds.width >= 120,
                bounds.height >= 80
            else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0 {
                return nil
            }

            let windowID = CGWindowID(windowNumber.uint32Value)
            let title = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isOnScreen =
                (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            return RunningAppWindowPreview(
                id: windowID,
                title: title?.isEmpty == false ? title! : app.localizedName ?? "Window",
                bounds: bounds,
                image: nil,
                minimized: !isOnScreen
            )
        }
        .prefix(5)

        var previews = Array(result)

        // CGWindowList only returns on-screen windows. Merge in the app's other windows
        // via Accessibility — minimized windows and windows on other Spaces — so the
        // hover peek is a real alt-tab of ALL the app's windows, not just visible ones.
        let axPreviews = axWindowPreviews(for: app)
        let minimizedTitles = Set(
            axPreviews.filter(\.minimized).map { $0.title.lowercased() })
        previews = previews.map { preview in
            var updated = preview
            if minimizedTitles.contains(preview.title.lowercased()) {
                updated.minimized = true
            }
            return updated
        }
        var knownTitles = Set(previews.map { $0.title.lowercased() })
        for axWin in axPreviews where knownTitles.insert(axWin.title.lowercased()).inserted {
            previews.append(axWin)
            if previews.count >= 5 { break }
        }

        cache[pid] = (Date(), previews)
        return previews
    }

    /// Accessibility enumeration of ALL the app's windows, including minimized ones
    /// (which CGWindowList omits). Minimized entries carry no live screenshot — the
    /// panel shows the app icon + title for those.
    private func axWindowPreviews(for app: NSRunningApplication) -> [RunningAppWindowPreview] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
                == .success,
            let windows = windowsRef as? [AXUIElement]
        else { return [] }

        return windows.prefix(6).enumerated().map { index, window in
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let rawTitle = (titleRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var minRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef)
            let minimized = (minRef as? Bool) ?? ((minRef as? NSNumber)?.boolValue ?? false)
            return RunningAppWindowPreview(
                id: CGWindowID(0xFFFF_0000 &+ UInt32(index)),  // synthetic, no CG image
                title: (rawTitle?.isEmpty == false) ? rawTitle! : (app.localizedName ?? "Window"),
                bounds: .zero,
                image: nil,
                minimized: minimized)
        }
    }

    private func refreshScreenshots(
        for app: NSRunningApplication,
        previews requestedPreviews: [RunningAppWindowPreview]
    ) {
        let pid = app.processIdentifier
        let ids = Set(requestedPreviews.map(\.id))
        guard !ids.isEmpty else { return }
        Task {
            guard
                let content = try? await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
            else { return }

            var images: [CGWindowID: CGImage] = [:]
            for window in content.windows where ids.contains(CGWindowID(window.windowID)) {
                guard let preview = requestedPreviews.first(where: { $0.id == CGWindowID(window.windowID) })
                else { continue }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                configuration.width = max(320, Int(preview.bounds.width * scale))
                configuration.height = max(200, Int(preview.bounds.height * scale))
                configuration.showsCursor = false
                if let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                ) {
                    images[CGWindowID(window.windowID)] = image
                }
            }

            guard !images.isEmpty else { return }
            await MainActor.run {
                guard self.activePID == pid else { return }
                let updated = self.previews.map { preview in
                    RunningAppWindowPreview(
                        id: preview.id,
                        title: preview.title,
                        bounds: preview.bounds,
                        image: images[preview.id] ?? preview.image
                    )
                }
                self.previews = updated
                self.cache[pid] = (Date(), updated)
            }
        }
    }

    private func refreshReviewScreenshots(
        for app: NSRunningApplication, previews requestedPreviews: [RunningAppWindowPreview]
    ) {
        let pid = app.processIdentifier
        let ids = Set(requestedPreviews.filter { $0.id < 0xFFFF_0000 }.map(\.id))
        guard !ids.isEmpty else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false) else { return }
            var images: [CGWindowID: CGImage] = [:]
            for window in content.windows where ids.contains(CGWindowID(window.windowID)) {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                config.width = 480
                config.height = 300
                config.showsCursor = false
                if let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config) {
                    images[CGWindowID(window.windowID)] = image
                }
            }
            guard !images.isEmpty else { return }
            await MainActor.run {
                guard let index = self.reviewGroups.firstIndex(where: { $0.id == pid }) else { return }
                self.reviewGroups[index].windows = self.reviewGroups[index].windows.map { preview in
                    guard let image = images[preview.id] else { return preview }
                    return RunningAppWindowPreview(
                        id: preview.id, title: preview.title, bounds: preview.bounds,
                        image: image, minimized: preview.minimized)
                }
            }
        }
    }

    private func bestAXWindowMatch(
        for preview: RunningAppWindowPreview,
        in windows: [AXUIElement]
    ) -> AXUIElement? {
        let normalizedTitle = preview.title.lowercased()
        return windows.first { window in
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                == .success,
                let title = titleRef as? String,
                !title.isEmpty
            else { return false }
            let candidate = title.lowercased()
            return candidate == normalizedTitle
                || candidate.contains(normalizedTitle)
                || normalizedTitle.contains(candidate)
        }
    }
}

struct RunningAppPreviewPanelView: View {
    @ObservedObject var service: RunningAppPreviewService

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                if let icon = service.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                }
                Text(service.appName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.94))
                    .lineLimit(1)
            }
            .padding(.top, 12)

            HStack(spacing: 16) {
                ForEach(service.previews) { preview in
                    Button {
                        service.focus(preview)
                    } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.black.opacity(0.24))
                                if let image = preview.image {
                                    Image(decorative: image, scale: 1)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 164, height: 106)
                                        .clipped()
                                } else if let icon = service.appIcon {
                                    // Minimized / off-Space window — no live pixels; show the
                                    // app icon so the window still appears in the peek.
                                    Image(nsImage: icon)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 48, height: 48)
                                        .opacity(0.85)
                                } else {
                                    Image(systemName: "rectangle.dashed")
                                        .font(.system(size: 28, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 164, height: 106)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                if preview.minimized {
                                    Text("Minimized")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Color.black.opacity(0.5), in: Capsule())
                                        .padding(5)
                                }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                            }

                            Text(preview.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.88))
                                .lineLimit(1)
                                .frame(width: 164)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.13), .white.opacity(0.035)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 28, x: 0, y: 14)
        }
        .onHover { hovering in
            if hovering {
                service.keepVisible()
            } else {
                service.scheduleHide()
            }
        }
    }
}

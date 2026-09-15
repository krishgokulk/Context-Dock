import AppKit
import ApplicationServices
import SwiftUI

enum CornerWindowRowMetrics {
    static let thumb = CGSize(width: 160, height: 100)
    static let gap: CGFloat = 8
    static let inset: CGFloat = 12
    static let titleHeight: CGFloat = 16
    /// Pure: count in, size out. The row is a corner slot and hit-tested by this number.
    static func size(count: Int) -> CGSize {
        let n = CGFloat(max(1, count))
        return CGSize(
            width: 2 * inset + n * thumb.width + (n - 1) * gap,
            height: 2 * inset + thumb.height + 4 + titleHeight)
    }
}

/// The hovered app's windows, one thumbnail each — the Dock's Exposé, at strip size. A
/// click raises that window. With Screen Recording refused the titles still show, so the
/// row says what is open rather than showing nothing and looking broken.
struct CornerWindowRow: View {
    let bundleID: String
    @ObservedObject var model: AppChatPromptModel
    @ObservedObject private var snapshots = AppWindowSnapshotService.shared

    private typealias M = CornerWindowRowMetrics

    var body: some View {
        let windows = snapshots.windowSnapshots(for: bundleID)
        let size = M.size(count: windows.count)
        HStack(spacing: M.gap) {
            if windows.isEmpty {
                placeholder
            }
            ForEach(windows) { window in
                VStack(spacing: 4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                        if let image = window.image {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Image(systemName: "macwindow")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: M.thumb.width, height: M.thumb.height)
                    Text(window.title.isEmpty ? "Untitled" : window.title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .frame(width: M.thumb.width, height: M.titleHeight)
                }
                .contentShape(Rectangle())
                .onTapGesture { raise(window) }
                .accessibilityLabel(window.title)
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(M.inset)
        .frame(width: size.width, height: size.height)
        .onHover { inside in model.windowRowHovered(inside) }
        .onAppear { snapshots.refreshWindows(bundleID: bundleID) }
        .onChange(of: bundleID) { _, next in snapshots.refreshWindows(bundleID: next) }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: snapshots.isDenied ? "eye.slash" : "macwindow")
                .font(.system(size: 24)).foregroundStyle(.secondary)
            Text(snapshots.isDenied ? "Allow Screen Recording to see windows" : "No windows")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(width: M.thumb.width, height: M.thumb.height + 4 + M.titleHeight)
    }

    /// Raise by window id through AX: the app's window elements carry `_AXWindowNumber`,
    /// which is the CGWindowID ScreenCaptureKit reports.
    private func raise(_ window: WindowSnapshot) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
            == .success,
            let windows = value as? [AXUIElement]
        {
            for element in windows {
                var number: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, "_AXWindowNumber" as CFString, &number)
                    == .success,
                    let n = number as? Int, CGWindowID(n) == window.id
                {
                    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                    break
                }
            }
        }
        app.activate()
        model.dismiss()
    }
}

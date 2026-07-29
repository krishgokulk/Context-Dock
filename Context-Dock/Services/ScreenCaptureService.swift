import AppKit
import SwiftUI
import Vision

final class ScreenCaptureService: @unchecked Sendable {
    static let shared = ScreenCaptureService()
    private let captureLock = NSLock()
    private init() {}

    enum CaptureKind {
        case text
        case area
        case screenshot
    }

    func capture(_ kind: CaptureKind) {
        Task.detached(priority: .userInitiated) {
            // A global hotkey can be repeated while the native selection overlay is
            // still up. Launching two screencapture pickers makes both appear to fail.
            guard self.captureLock.try() else {
                await MainActor.run {
                    AppToast.show("Capture already in progress", icon: "text.viewfinder", tint: .orange)
                }
                return
            }
            defer { self.captureLock.unlock() }

            // The old implementation relied on the child `screencapture` process to
            // signal this failure. It then returned silently, which looked exactly
            // like a broken hotkey. Ask through our app identity and make the next
            // action clear if macOS still denies the permission.
            let canCapture = await MainActor.run { () -> Bool in
                if CGPreflightScreenCaptureAccess() { return true }
                return CGRequestScreenCaptureAccess() && CGPreflightScreenCaptureAccess()
            }
            guard canCapture else {
                await MainActor.run {
                    AppToast.show(
                        "Capture Text needs Screen Recording access — allow Context Dock in Privacy & Security",
                        icon: "text.viewfinder", tint: .orange)
                }
                return
            }

            // Resolve the source app BEFORE screencapture takes over the front: the
            // clipboard scope shows "Copied from …", and once the picker is up the
            // frontmost app is screencapture, not the app the user grabbed from.
            let source = await MainActor.run { Self.captureSourceApp() }

            let isSavedImage: Bool
            switch kind {
            case .area, .screenshot: isSavedImage = true
            case .text: isSavedImage = false
            }
            let url: URL
            if isSavedImage {
                // User-selected folder (Settings → Hotkeys), falling back to ~/Pictures.
                let dir = await MainActor.run { AppSettings.shared.captureSaveDirectory }
                try? FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                let name = "Screenshot \(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).png"
                url = dir.appendingPathComponent(name)
            } else {
                url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("context-dock-hotkey-capture-\(UUID().uuidString).png")
            }
            defer {
                if !isSavedImage { try? FileManager.default.removeItem(at: url) }
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            switch kind {
            case .screenshot:
                // No -x: let screencapture play the native shutter sound so the user gets
                // audible feedback that the full-screen shot was taken.
                process.arguments = [url.path]
            case .text, .area:
                process.arguments = ["-i", url.path]
            }
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                await MainActor.run {
                    AppToast.show(
                        "Couldn’t start the screen capture picker", icon: "text.viewfinder", tint: .red)
                }
                return
            }
            // Non-zero status is the user pressing Escape on the picker — stay silent.
            guard process.terminationStatus == 0 else { return }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                await MainActor.run {
                    AppToast.show(
                        "Capture produced no image — try selecting the text again",
                        icon: "text.viewfinder", tint: .orange)
                }
                return
            }

            switch kind {
            case .text:
                let text = Self.recognizeText(in: url)
                guard !text.isEmpty else {
                    await MainActor.run {
                        AppToast.show(
                            "No text found in that capture", icon: "text.viewfinder", tint: .orange)
                    }
                    return
                }
                await MainActor.run {
                    // Write + publish in one main-thread hop so the clipboard poll can
                    // never import this clip between the two and lose the source app.
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    ClipboardIngestBus.shared.publish(
                        ClipboardCapturePayload(
                            content: .text(text),
                            sourceAppName: source.name,
                            sourceBundleId: source.bundleId,
                            pasteboardChangeCount: pasteboard.changeCount
                        )
                    )
                    NSSound(named: "Tink")?.play()
                    let words = text.split(whereSeparator: { $0.isWhitespace }).count
                    AppToast.show(
                        "Text copied — \(words) \(words == 1 ? "word" : "words") ready to paste",
                        icon: "text.viewfinder", tint: .green)
                }
            case .area, .screenshot:
                guard let image = NSImage(data: data) else { return }
                let pngData = ClipboardImageStore.pngData(from: data) ?? data
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([image])
                    ClipboardIngestBus.shared.publish(
                        ClipboardCapturePayload(
                            content: .image(pngData, savedFilePath: url.path),
                            sourceAppName: source.name,
                            sourceBundleId: source.bundleId,
                            pasteboardChangeCount: pasteboard.changeCount
                        )
                    )
                    // Audible "copied to clipboard" confirmation so the user knows the shot
                    // landed on the clipboard (and in our clipboard history).
                    NSSound(named: "Tink")?.play()
                    AppToast.show(
                        "Screenshot copied — saved to \(url.deletingLastPathComponent().lastPathComponent)",
                        icon: "camera.viewfinder", tint: .green)
                }
            }
        }
    }

    // MARK: - Helpers

    @MainActor
    private static func captureSourceApp() -> (name: String, bundleId: String) {
        let ownBundleId = Bundle.main.bundleIdentifier
        let candidates = [
            NSWorkspace.shared.frontmostApplication,
            AppDelegate.shared?.previousFrontmostApp,
        ]
        for app in candidates.compactMap({ $0 })
        where app.bundleIdentifier != ownBundleId && app.bundleIdentifier != "com.apple.screencapture" {
            return (app.localizedName ?? "", app.bundleIdentifier ?? "")
        }
        return ("", "")
    }

    private static func recognizeText(in url: URL) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(url: url, options: [:]).perform([request])
        } catch {
            return ""
        }
        // Vision does not guarantee array order. Rebuild reading order from the
        // observations' image-space bounds: top-to-bottom, then left-to-right
        // within the same visual line. This keeps paragraphs, menus, and tables
        // useful after they land on the clipboard.
        let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
            guard let text = observation.topCandidates(1).first?.string
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }
            return OCRLine(text: text, bounds: observation.boundingBox)
        }
        let ordered = lines.sorted { lhs, rhs in
            let lineTolerance = max(lhs.bounds.height, rhs.bounds.height) * 0.55
            if abs(lhs.bounds.midY - rhs.bounds.midY) <= lineTolerance {
                return lhs.bounds.minX < rhs.bounds.minX
            }
            return lhs.bounds.midY > rhs.bounds.midY
        }
        return ordered
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct OCRLine {
        let text: String
        let bounds: CGRect
    }
}

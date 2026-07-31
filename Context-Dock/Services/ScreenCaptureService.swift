import AppKit
import SwiftUI
import Vision

/// Text Snipper + screenshot capture.
///
/// Everything here funnels through `/usr/sbin/screencapture -i`, which needs three
/// things the old implementation left to chance: Screen Recording permission (without
/// it the picker never draws and the file is never written), a clear screen (our own
/// launcher sits at status-window level, so it drew *over* the crosshair and ended up
/// inside the shot), and feedback — every failure used to `return` in silence, which is
/// what "Capture Text doesn't work" looked like from the outside.
final class ScreenCaptureService: @unchecked Sendable {
    static let shared = ScreenCaptureService()
    private init() {}

    enum CaptureKind {
        case text
        case area
        case screenshot
    }

    func capture(_ kind: CaptureKind) {
        Task.detached(priority: .userInitiated) {
            // Resolve the source app BEFORE screencapture takes over the front: the
            // clipboard scope shows "Copied from …", and once the picker is up the
            // frontmost app is screencapture, not the app the user grabbed from.
            // Snapshot the source app AND whether the dock was up in the *same* main-thread
            // hop the hotkey lands on. Reading visibility later was the bug behind "the dock
            // never came back": anything that hid the panel in the milliseconds between the
            // key press and this task made the snapshot read `false`, and a false snapshot
            // means nothing gets restored afterwards.
            let (source, dockWasVisible) = await MainActor.run {
                (Self.captureSourceApp(), Self.launcherIsOnScreen())
            }
            guard await Self.ensureScreenRecordingAccess() else {
                await MainActor.run { Self.restoreOwnWindows(dockWasVisible) }
                return
            }
            await Self.hideOwnWindowsForCapture(dockWasVisible)

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
            case .area:
                process.arguments = ["-i", url.path]
            case .text:
                // -x mutes the shutter: a text snip is not a screenshot, and the Tink
                // below is the confirmation that matters.
                process.arguments = ["-i", "-x", url.path]
            }
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                await MainActor.run {
                    Self.restoreOwnWindows(dockWasVisible)
                    AppToast.show(
                        "Capture failed to start", icon: "exclamationmark.triangle", tint: .orange)
                }
                return
            }
            // Put the dock back the moment the picker is gone — before OCR, so the scope
            // the user was in reappears immediately rather than after recognition.
            await MainActor.run { Self.restoreOwnWindows(dockWasVisible) }
            // Escape on the picker exits non-zero and writes nothing — that is a
            // deliberate cancel, so stay silent. A zero exit with no file is a real
            // failure and must say so.
            guard process.terminationStatus == 0 else { return }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                await MainActor.run {
                    AppToast.show(
                        "Nothing captured — try selecting a larger area",
                        icon: "viewfinder", tint: .orange)
                }
                return
            }

            switch kind {
            case .text:
                let text = Self.recognizeText(in: data)
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
                    // Same confidence the screenshot toast gives: show what was actually
                    // snipped, not just that something happened.
                    AppToast.show(
                        Self.snippetSummary(for: text),
                        icon: "text.viewfinder", tint: .green, duration: 3.5,
                        actionTitle: "Clipboard",
                        action: {
                            NotificationCenter.default.post(
                                name: .activateClipboardScope, object: nil)
                        })
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

    // MARK: - Preconditions

    /// `screencapture` runs under *our* Screen Recording grant. Without it the picker
    /// never appears and the command quietly writes nothing, so ask up front and send
    /// the user straight to the right Settings pane.
    @MainActor
    private static func ensureScreenRecordingAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // Fires the system prompt the first time; a no-op once the user has answered.
        if CGRequestScreenCaptureAccess() { return true }
        AppToast.show(
            "Screen Recording permission needed to capture",
            icon: "lock.shield", tint: .orange, duration: 6,
            actionTitle: "Open Settings",
            action: {
                if let url = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                ) {
                    NSWorkspace.shared.open(url)
                }
            })
        return false
    }

    /// The launcher panel lives at status-window level — above screencapture's crosshair
    /// overlay. Left on screen it swallowed the drag and landed inside the captured
    /// image; anything behind it could never be snipped at all.
    ///
    /// This orders the window out directly rather than calling `hideLauncher(force:)`:
    /// a forced hide *ends the session* — it drops `smartScopeActive`, clears the active
    /// scope key and unpins — so capturing from inside an app or Terminal scope threw
    /// that scope away. Taking the panel off screen changes nothing the user set up, and
    /// `restoreOwnWindows` puts it back exactly as it was.
    @MainActor
    private static func launcherIsOnScreen() -> Bool {
        let window = AppDelegate.shared?.launcherWindow
        #if DEBUG
        let visibleWindows = NSApp.windows
            .filter { $0.isVisible }
            .map { "\(type(of: $0))<\($0.windowNumber)> a=\($0.alphaValue)" }
            .joined(separator: ", ")
        NSLog(
            "[capture] snapshot delegate=\(AppDelegate.shared != nil) "
                + "launcherWindow=\(window.map { "#\($0.windowNumber)" } ?? "nil") "
                + "isVisible=\(window?.isVisible ?? false) alpha=\(window?.alphaValue ?? -1) "
                + "key=\(window?.isKeyWindow ?? false) appActive=\(NSApp.isActive) "
                + "onScreen=[\(visibleWindows)]")
        #endif
        return window?.isVisible == true
    }

    @MainActor
    private static func hideOwnWindowsForCapture(_ dockWasVisible: Bool) async {
        AppToast.hide()
        guard dockWasVisible, let delegate = AppDelegate.shared,
            let window = delegate.launcherWindow
        else { return }

        // screencapture activates itself, so our panel resigns key and the normal
        // focus-loss path starts hiding the dock for real — including a 0.15s fade whose
        // completion handler orders the window out *after* we have put it back. Suppress
        // that path for the whole capture instead of racing it.
        delegate.suppressHideOnResignUntil = Date().addingTimeInterval(Self.captureHoldSeconds)
        #if DEBUG
        NSLog("[capture] hiding dock for picker")
        #endif
        window.orderOut(nil)
        // Give the window server a beat to actually take the panel off screen before
        // the picker starts compositing.
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// Long enough for an unhurried drag; the hold is released the moment the picker ends.
    private static let captureHoldSeconds: TimeInterval = 300

    @MainActor
    private static func restoreOwnWindows(_ wasVisible: Bool) {
        #if DEBUG
        NSLog("[capture] restore requested wasVisible=\(wasVisible)")
        #endif
        guard let delegate = AppDelegate.shared else { return }
        guard wasVisible, let window = delegate.launcherWindow else {
            delegate.suppressHideOnResignUntil = .distantPast
            return
        }
        window.alphaValue = 1
        // orderFrontRegardless keeps the app non-activating: the dock comes back floating
        // over whatever the user captured from, which stays frontmost.
        window.orderFrontRegardless()
        #if DEBUG
        NSLog("[capture] restored dock, isVisible=\(window.isVisible)")
        #endif
        // A short tail: the captured app activates right after the picker closes, which
        // is one more resign the dock should survive. Then normal behaviour resumes.
        delegate.suppressHideOnResignUntil = Date().addingTimeInterval(0.8)
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

    /// Toast copy for a finished snip: the opening words of what was read, plus the size
    /// of the rest, so the user can confirm the right region was captured without pasting.
    private static func snippetSummary(for text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let firstLine =
            text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? text
        let preview = firstLine.count > 30 ? String(firstLine.prefix(30)) + "…" : firstLine
        let scale = words == 1 ? "1 word" : "\(words) words"
        return preview.isEmpty ? "Text copied — \(scale)" : "Copied “\(preview)”"
    }

    // MARK: - Recognition

    private static func recognizeText(in data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return "" }

        if let text = recognize(image), !text.isEmpty { return text }

        // A tight snip around a single word or a line of small UI text can be too few
        // pixels for the recogniser. One upscaled retry costs milliseconds and rescues
        // exactly the captures a text snipper is used for.
        guard let upscaled = upscale(image, factor: 3), let text = recognize(upscaled) else {
            return ""
        }
        return text
    }

    private static func recognize(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Default is 1/32 of the image height — on a full-screen grab that discards
        // ordinary body text. A snipper must read whatever is inside the rectangle.
        request.minimumTextHeight = 0
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return readingOrderText(from: request.results ?? [])
    }

    /// Vision returns observations without a guaranteed layout order, so raw joining
    /// scrambles documents, webpages and anything with columns. Group observations that
    /// share a baseline into lines, order each line left→right, then lines top→bottom.
    private static func readingOrderText(from observations: [VNRecognizedTextObservation]) -> String {
        let boxes = observations.compactMap { observation -> (text: String, box: CGRect)? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (candidate.string, observation.boundingBox)
        }
        guard !boxes.isEmpty else { return "" }

        var lines: [[(text: String, box: CGRect)]] = []
        // Vision's origin is bottom-left: descending midY walks the page top to bottom.
        for item in boxes.sorted(by: { $0.box.midY > $1.box.midY }) {
            let tolerance = max(item.box.height, 0.005) * 0.6
            if var line = lines.last, let reference = line.first,
                abs(reference.box.midY - item.box.midY) <= tolerance
            {
                line.append(item)
                lines[lines.count - 1] = line
            } else {
                lines.append([item])
            }
        }

        return
            lines
            .map { line in
                line.sorted { $0.box.minX < $1.box.minX }
                    .map(\.text)
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func upscale(_ image: CGImage, factor: Int) -> CGImage? {
        let width = image.width * factor
        let height = image.height * factor
        // Guard against a huge source turning into a gigapixel retry.
        guard width * height <= 40_000_000 else { return nil }
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

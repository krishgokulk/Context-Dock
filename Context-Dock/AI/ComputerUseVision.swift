// ComputerUseVision.swift
// Context-Dock
//
// The last rung of the observe → act → verify loop: reading pixels when an app exposes nothing
// through Accessibility (canvas apps, custom-drawn UIs). The window is captured with
// ScreenCaptureKit and run through Vision OCR; every recognised line becomes a target `t1`,
// `t2`… with the point to click. The model still names an id, never a coordinate.
//
// Pixel clicks are the least certain thing Computer Use does, so `ComputerUseAXRunner` asks
// for approval on every one of them whatever mode the app is in.

import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

struct PixelTarget {
    let id: String
    let label: String
    /// Global screen point (top-left origin), the space CGEvent uses.
    let point: CGPoint
}

@MainActor
enum ComputerUseVision {

    private static var targets: [String: [String: PixelTarget]] = [:]
    private static let maxTargets = 80

    static func isPixelID(_ id: String) -> Bool { id.hasPrefix("t") && id.dropFirst().allSatisfy(\.isNumber) && id.count > 1 }

    static func target(id: String, bundleID: String) -> PixelTarget? { targets[bundleID]?[id] }

    /// Capture the app's largest on-screen window and list its text with click points.
    static func read(bundleID: String, appName: String) async -> String? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            guard
                let window = content.windows
                    .filter({
                        $0.owningApplication?.bundleIdentifier == bundleID && $0.isOnScreen
                            && $0.frame.width > 80 && $0.frame.height > 80
                    })
                    .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else { return nil }

            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * 2)
            config.height = Int(window.frame.height * 2)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: config)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

            let frame = window.frame
            var table: [String: PixelTarget] = [:]
            var lines: [String] = []
            for observation in (request.results ?? []).prefix(maxTargets) {
                guard let text = observation.topCandidates(1).first?.string,
                    !text.trimmingCharacters(in: .whitespaces).isEmpty
                else { continue }
                let id = "t\(table.count + 1)"
                let box = observation.boundingBox  // normalised, origin bottom-left
                let point = CGPoint(
                    x: frame.minX + box.midX * frame.width,
                    y: frame.minY + (1 - box.midY) * frame.height)
                table[id] = PixelTarget(id: id, label: String(text.prefix(80)), point: point)
                lines.append("[\(id)] text \"\(String(text.prefix(80)))\"")
            }
            targets[bundleID] = table
            guard !lines.isEmpty else { return nil }
            return "\(appName) — read from pixels (OCR). Targets are clickable text only and are "
                + "less certain than element ids; prefer ax elements when the app has them.\n"
                + lines.joined(separator: "\n")
        } catch {
            return nil
        }
    }

    // MARK: Input

    static func click(at point: CGPoint, pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let event = CGEvent(
                mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                mouseButton: .left)
            event?.postToPid(pid)
        }
    }

    /// Click the target to focus it, then paste `text`. The pasteboard is restored afterwards.
    static func typeText(_ text: String, at point: CGPoint, pid: pid_t) async {
        click(at: point, pid: pid)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let pasteboard = NSPasteboard.general
        let old = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: down)
            event?.flags = .maskCommand
            event?.postToPid(pid)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        pasteboard.clearContents()
        if let old { pasteboard.setString(old, forType: .string) }
    }
}

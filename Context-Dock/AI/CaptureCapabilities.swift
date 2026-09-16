// CaptureCapabilities.swift
// Context-Dock
//
// Capture Text and Capture Area, reachable by the model.
//
// Both existed as hotkeys only. `system.captureScreenshot` grabs the whole screen, so
// "read the error in that panel" had no route: the model could take a full-screen shot it
// then could not read, or nothing. Meanwhile Capture Text — a region snip with OCR — was
// one keystroke away and invisible.
//
// These are the first capabilities that *wait for the user*. The picker is a drag on
// screen, so the executor cannot report a result until that has happened, and it cannot
// know whether the user meant to cancel. Both are treated as answers: a completed capture
// returns what it produced, an abandoned one says nothing was captured. Neither invents a
// result, which for a capability whose whole output is "what was on screen" would be the
// worst possible failure.

import AppKit
import Foundation

@MainActor
enum CaptureCapabilities {

    /// A picker is a person dragging a rectangle. Long enough not to give up on someone
    /// choosing carefully, short enough that an abandoned capture does not hold the turn
    /// open indefinitely.
    private static let pickerTimeout: TimeInterval = 60

    static func register(in registry: CapabilityRegistry) {
        registerCaptureText(registry)
        registerCaptureArea(registry)
    }

    private static func registerCaptureText(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "capture.text",
                title: "Capture Text from Screen (OCR)",
                appBundleID: nil,
                inputSchema: .init(fields: []),
                // Same reasoning as the screenshot capability: screen contents may hold
                // anything, so the user approves the grab even though it changes nothing.
                riskLevel: .medium
            ) { _ in
                let pasteboard = NSPasteboard.general
                let before = pasteboard.changeCount
                ScreenCaptureService.shared.capture(.text)

                // The service writes the recognised text to the pasteboard when it
                // succeeds, so the clipboard changing is the completion signal — no need to
                // reach into the service or duplicate its OCR.
                guard await waitForChange(deadline: Date().addingTimeInterval(pickerTimeout), {
                    pasteboard.changeCount != before
                }) else {
                    return .init(
                        success: false,
                        output: "No text was captured — the selection was cancelled, or "
                            + "nothing readable was in it.")
                }
                let text = pasteboard.string(forType: .string) ?? ""
                guard !text.isEmpty else {
                    return .init(success: false, output: "The capture produced no text.")
                }
                return .init(success: true, output: "Captured text:\n\n\(text)")
            }
        )
    }

    private static func registerCaptureArea(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "capture.area",
                title: "Capture a Region of the Screen",
                appBundleID: nil,
                inputSchema: .init(fields: []),
                riskLevel: .medium
            ) { _ in
                let directory = AppSettings.shared.captureSaveDirectory
                let before = newestImage(in: directory)
                ScreenCaptureService.shared.capture(.area)

                // An area capture is saved as a file rather than put on the clipboard, so a
                // newer image in the save folder is what "it finished" looks like.
                guard await waitForChange(deadline: Date().addingTimeInterval(pickerTimeout), {
                    let now = newestImage(in: directory)
                    return now != nil && now?.path != before?.path
                }), let captured = newestImage(in: directory) else {
                    return .init(
                        success: false,
                        output: "No region was captured — the selection was cancelled.")
                }
                // Same shelf the screenshot capability writes to, so "the spacing is still
                // wrong" can hand this straight to the coding agent.
                WorkbenchEvidence.shared.recordCapture(captured)
                return .init(
                    success: true, output: "Captured the region to \(captured.path).")
            }
        )
    }

    // MARK: - Helpers

    /// Polls until `condition` holds or the deadline passes. Coarse on purpose: this is
    /// waiting on a human, where a quarter second is imperceptible and a tight loop only
    /// burns battery while someone decides what to select.
    private static func waitForChange(
        deadline: Date, _ condition: @MainActor () -> Bool
    ) async -> Bool {
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private static func newestImage(in directory: URL) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)
        else { return nil }
        return files
            .filter { $0.pathExtension.lowercased() == "png" }
            .map {
                ($0, (try? $0.resourceValues(forKeys: Set(keys)))?.contentModificationDate
                    ?? .distantPast)
            }
            .max { $0.1 < $1.1 }?
            .0
    }
}

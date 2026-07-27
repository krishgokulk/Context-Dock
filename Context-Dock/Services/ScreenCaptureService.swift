import AppKit
import Vision

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
            let isSavedImage: Bool
            switch kind {
            case .area, .screenshot: isSavedImage = true
            case .text: isSavedImage = false
            }
            let url: URL
            if isSavedImage,
                let pictures = FileManager.default.urls(
                    for: .picturesDirectory, in: .userDomainMask).first
            {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                let name = "Screenshot \(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).png"
                url = pictures.appendingPathComponent(name)
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
                return
            }
            guard process.terminationStatus == 0,
                let data = try? Data(contentsOf: url), !data.isEmpty
            else { return }

            switch kind {
            case .text:
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                do {
                    try VNImageRequestHandler(url: url, options: [:]).perform([request])
                } catch {
                    return
                }
                let text = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    NSSound(named: "Tink")?.play()
                }
            case .area, .screenshot:
                guard let image = NSImage(data: data) else { return }
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([image])
                    // Audible "copied to clipboard" confirmation so the user knows the shot
                    // landed on the clipboard (and in our clipboard history via the monitor).
                    NSSound(named: "Tink")?.play()
                }
            }
        }
    }
}

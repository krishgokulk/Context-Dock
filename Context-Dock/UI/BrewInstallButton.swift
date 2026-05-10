import SwiftUI
import Foundation

// MARK: - Inline Brew Install Button
// Shown in chat bubbles when AI says "brew install X".
// Tapping installs the tool and refreshes BinaryWatcherService.

struct BrewInstallButton: View {
    let toolName: String
    /// Called on the main actor after a successful install — use to auto-retry the original query.
    var onInstalled: (() -> Void)? = nil

    enum State { case idle, installing, done, failed(String) }
    @SwiftUI.State private var state: State = .idle

    var body: some View {
        Button(action: install) {
            HStack(spacing: 4) {
                switch state {
                case .idle:
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10, weight: .semibold))
                    Text("brew install \(toolName)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                case .installing:
                    ProgressView().scaleEffect(0.55)
                    Text("Installing \(toolName)…")
                        .font(.system(size: 10))
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text("\(toolName) installed")
                        .font(.system(size: 10))
                case .failed(let msg):
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(msg)
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(buttonForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(buttonBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isIdle)
    }

    private var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    private var buttonForeground: some ShapeStyle {
        switch state {
        case .idle:       return AnyShapeStyle(Color.accentColor)
        case .installing: return AnyShapeStyle(Color.secondary)
        case .done:       return AnyShapeStyle(Color.green)
        case .failed:     return AnyShapeStyle(Color.orange)
        }
    }

    private var buttonBackground: some ShapeStyle {
        switch state {
        case .idle:       return AnyShapeStyle(Color.accentColor.opacity(0.12))
        case .installing: return AnyShapeStyle(Color.secondary.opacity(0.08))
        case .done:       return AnyShapeStyle(Color.green.opacity(0.12))
        case .failed:     return AnyShapeStyle(Color.orange.opacity(0.12))
        }
    }

    private func install() {
        state = .installing
        Task {
            // Find brew binary (works on both Apple Silicon and Intel)
            let brewPath: String
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") {
                brewPath = "/opt/homebrew/bin/brew"
            } else if FileManager.default.fileExists(atPath: "/usr/local/bin/brew") {
                brewPath = "/usr/local/bin/brew"
            } else {
                await MainActor.run { state = .failed("brew not found") }
                return
            }

            let result = await Task.detached(priority: .userInitiated) { () -> (Bool, String) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: brewPath)
                p.arguments = ["install", toolName]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError  = pipe
                guard (try? p.run()) != nil else { return (false, "failed to start brew") }
                p.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return (p.terminationStatus == 0, out)
            }.value

            await MainActor.run {
                if result.0 {
                    state = .done
                    // Rescan binaries and deep-scan this specific tool's help tree
                    Task {
                        await BinaryWatcherService.shared.scanNow(skipHelpScan: true)
                        await TerminalPackageManager.shared.refreshHelpTextByCommand(toolName)
                        // Fire auto-retry callback after help is scanned
                        await MainActor.run { onInstalled?() }
                    }
                } else {
                    // Extract a short error from brew output
                    let lines = result.1.components(separatedBy: .newlines)
                    let errLine = lines.first(where: {
                        $0.lowercased().contains("error") || $0.lowercased().contains("not found")
                    }) ?? "Install failed"
                    state = .failed(String(errLine.prefix(40)))
                }
            }
        }
    }
}

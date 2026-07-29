import SwiftUI
import SwiftTerm
import Foundation

// MARK: - Terminal View Delegate
class TerminalHostController: NSObject {
    var terminalView: LocalProcessTerminalView!
    var onProcessTerminated: (() -> Void)?
    /// When true this is an embedded panel terminal — does NOT steal the AI bridge slot
    var isPanel: Bool = false
    /// CLI scopes render a captured, single-run command transcript here after the
    /// background executor has produced a real exit code and output.
    var showsCapturedExecutionTranscript = false

    // AI Integration: Output capture callback
    var onOutputReceived: ((String) -> Void)?
    var isCapturingForAI = false
    var aiOutputBuffer = ""

    init(isPanel: Bool = false) {
        self.isPanel = isPanel
        super.init()
        terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        terminalView.processDelegate = self

        // Configure terminal appearance
        terminalView.font = NSFont.monospacedSystemFont(ofSize: isPanel ? 11 : 13, weight: .regular)

        // Set terminal colors for dark theme
        terminalView.nativeForegroundColor = NSColor.white
        terminalView.nativeBackgroundColor = NSColor(
            red: isPanel ? 0.06 : 0.1,
            green: isPanel ? 0.06 : 0.1,
            blue: isPanel ? 0.08 : 0.12,
            alpha: 1.0
        )

        // Start the shell process
        startShell()

        // Only the main terminal registers with the AI bridge
        if !isPanel {
            Task { @MainActor in
                TerminalAIBridge.shared.terminalController = self
            }
        }
    }

    private func startShell() {
        let shell = getShell()
        let shellName = "-" + (shell as NSString).lastPathComponent

        // Change to home directory
        FileManager.default.changeCurrentDirectoryPath(FileManager.default.homeDirectoryForCurrentUser.path)

        terminalView.startProcess(executable: shell, execName: shellName)
        
        // Give terminal focus after starting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.terminalView.window?.makeFirstResponder(self?.terminalView)
        }
    }

    private func getShell() -> String {
        // Try to get user's default shell from passwd
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize != -1 else {
            return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        }

        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: Int(bufsize))
        defer { buffer.deallocate() }

        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?

        if getpwuid_r(getuid(), &pwd, buffer, Int(bufsize), &result) == 0 {
            return String(cString: pwd.pw_shell)
        }

        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
    
    // Helper to send commands to terminal
    func sendCommand(_ command: String) {
        guard let data = (command + "\n").data(using: .utf8) else { return }
        let bytes = [UInt8](data)
        terminalView.send(data: bytes[...])
    }

    /// Injects raw keystrokes into the running PTY — no newline appended.
    /// Use this to control interactive TUI apps (menus, vim, etc.).
    /// Supports special sequences: "\r" = Enter, "\u{1B}" = Esc, "\u{03}" = Ctrl-C,
    /// "\u{1B}[A/B/C/D" = arrow keys.
    func sendKeys(_ keys: String) {
        guard let data = keys.data(using: .utf8) else { return }
        let bytes = [UInt8](data)
        terminalView.send(data: bytes[...])
    }

    /// Render a completed execution without sending it through the shell again. This
    /// avoids duplicate side effects while preserving a readable terminal transcript.
    func appendExecutionTranscript(command: String, output: String, exitCode: Int32) {
        let statusColor = exitCode == 0 ? "\u{001B}[32m" : "\u{001B}[31m"
        let cleanOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = cleanOutput.isEmpty ? "(no output)" : cleanOutput
        let transcript = "\r\n\u{001B}[2m$ \(command)\u{001B}[0m\r\n\(body)\r\n\(statusColor)exit \(exitCode)\u{001B}[0m\r\n"
        terminalView.feed(text: transcript)
    }

}

// MARK: - LocalProcessTerminalViewDelegate Methods
extension TerminalHostController: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Size changes are handled automatically by the terminal view
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Title changes can be handled if needed in the UI
    }

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        // Directory changes can be handled if needed
    }

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            // Restart the shell when it terminates
            self?.startShell()
        }
    }
}

// MARK: - SwiftUI Wrapper
struct TerminalNSViewRepresentable: NSViewRepresentable {
    let terminalController: TerminalHostController

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = terminalController.terminalView!
        
        // Make sure the terminal can accept first responder
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Ensure terminal stays as first responder when view updates
        if nsView.window?.firstResponder != nsView {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

// MARK: - Panel Embedded Terminal (per-panel PTY, doesn't steal first-responder)

/// Lightweight wrapper for embedding a real PTY inside the app-panel drawer.
/// Grants first-responder on appear so TUI keyboard input goes to the terminal, not the search field.
struct PanelTerminalView: NSViewRepresentable {
    let controller: TerminalHostController

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = controller.terminalView!
        // Give keyboard focus immediately so TUI apps get input
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Re-claim focus if the window still has it and another view stole it
        if let win = nsView.window, win.isKeyWindow, !(win.firstResponder is NSTextField) {
            if win.firstResponder !== nsView {
                win.makeFirstResponder(nsView)
            }
        }
    }
}

// MARK: - Terminal Resize Handle (renamed to avoid conflict)
struct TerminalResizeHandle: View {
    @Binding var height: CGFloat
    @Binding var isDragging: Bool
    let minHeight: CGFloat
    let maxHeight: CGFloat
    
    @State private var initialHeight: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 12)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(isDragging ? Color.green.opacity(0.6) : Color.white.opacity(0.3))
                    .frame(width: 40, height: 4)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            initialHeight = height
                        }
                        
                        let newHeight = initialHeight + value.translation.height
                        let clampedHeight = min(maxHeight, max(minHeight, newHeight))
                        
                        // Calculate the height change
                        let heightDelta = clampedHeight - height
                        height = clampedHeight
                        
                        // Adjust window size as terminal resizes
                        if let window = NSApp.keyWindow {
                            let currentFrame = window.frame
                            var newFrame = currentFrame
                            newFrame.size.height = currentFrame.height + heightDelta
                            newFrame.origin.y = currentFrame.origin.y - heightDelta
                            
                            // Check screen bounds
                            if let screen = window.screen {
                                let screenFrame = screen.visibleFrame
                                
                                if newFrame.maxY > screenFrame.maxY {
                                    let overflow = newFrame.maxY - screenFrame.maxY
                                    newFrame.origin.y -= overflow
                                }
                                
                                if newFrame.origin.y < screenFrame.origin.y {
                                    newFrame.origin.y = screenFrame.origin.y
                                }
                            }
                            
                            window.setFrame(newFrame, display: true, animate: false)
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

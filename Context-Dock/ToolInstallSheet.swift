import SwiftUI
import Foundation

// MARK: - Install Method

enum ToolInstallMethod: String, CaseIterable, Identifiable {
    case brew       = "Homebrew"
    case npm        = "npm (Node)"
    case pip        = "pip (Python)"
    case cargo      = "cargo (Rust)"
    case goInstall  = "go install"
    case gitClone   = "git clone + build"
    case custom     = "Custom script"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .brew:      return "cup.and.saucer"
        case .npm:       return "curlybraces"
        case .pip:       return "chevron.left.forwardslash.chevron.right"
        case .cargo:     return "gearshape"
        case .goInstall: return "arrow.right.circle"
        case .gitClone:  return "arrow.triangle.branch"
        case .custom:    return "terminal"
        }
    }

    var placeholder: String {
        switch self {
        case .brew:      return "formula-name  (e.g. yt-dlp)"
        case .npm:       return "package-name  (e.g. @anthropic-ai/claude-code)"
        case .pip:       return "package-name  (e.g. eyed3)"
        case .cargo:     return "crate-name  (e.g. bat)"
        case .goInstall: return "module@version  (e.g. github.com/nicholasgasior/gsfmt@latest)"
        case .gitClone:  return "https://github.com/user/repo"
        case .custom:    return "Paste shell commands here…"
        }
    }

    var requiresMultiLine: Bool { self == .gitClone || self == .custom }
}

// MARK: - ToolInstallSheet

struct ToolInstallSheet: View {
    /// Optional pre-selected tool name (shown as title / pre-filled package field)
    var toolName: String
    var onInstalled: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var method: ToolInstallMethod = .brew
    @State private var packageInput: String = ""
    @State private var buildScript: String = ""   // for gitClone: custom build steps after clone
    @State private var installPath: String = ""   // for gitClone: where to install binary (optional)

    @State private var log: String = ""
    @State private var isRunning = false
    @State private var finished = false
    @State private var success = false

    // Detected available package managers
    private let availableMethods: [ToolInstallMethod] = {
        var list: [ToolInstallMethod] = []
        let fm = FileManager.default
        let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        if brewPaths.contains(where: { fm.fileExists(atPath: $0) }) { list.append(.brew) }
        let npmPaths = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
        if npmPaths.contains(where: { fm.fileExists(atPath: $0) }) { list.append(.npm) }
        let pipPaths = ["/opt/homebrew/bin/pip3", "/usr/local/bin/pip3", "/usr/bin/pip3"]
        if pipPaths.contains(where: { fm.fileExists(atPath: $0) }) { list.append(.pip) }
        let cargoPaths = ["\(NSHomeDirectory())/.cargo/bin/cargo"]
        if cargoPaths.contains(where: { fm.fileExists(atPath: $0) }) { list.append(.cargo) }
        let goPaths = ["/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/local/bin/go"]
        if goPaths.contains(where: { fm.fileExists(atPath: $0) }) { list.append(.goInstall) }
        list.append(.gitClone)
        list.append(.custom)
        return list
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install \(toolName.isEmpty ? "Tool" : toolName)")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Choose an install method")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 0) {
                // Left: method picker
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(availableMethods) { m in
                        Button(action: { method = m; log = "" }) {
                            HStack(spacing: 8) {
                                Image(systemName: m.systemImage)
                                    .frame(width: 16)
                                    .foregroundColor(method == m ? .accentColor : .secondary)
                                Text(m.rawValue)
                                    .font(.system(size: 12, weight: method == m ? .semibold : .regular))
                                    .foregroundColor(method == m ? .primary : .secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(method == m ? Color.accentColor.opacity(0.12) : Color.clear)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .frame(width: 150)
                .padding(.top, 10)
                .padding(.leading, 8)

                Divider()

                // Right: config + log
                VStack(alignment: .leading, spacing: 12) {
                    if !finished {
                        inputSection
                    }
                    logSection
                }
                .padding(16)
            }

            Divider()

            // Footer
            HStack {
                if finished {
                    Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(success ? .green : .red)
                    Text(success ? "\(toolName) installed successfully" : "Install failed — check log above")
                        .font(.system(size: 12))
                        .foregroundColor(success ? .green : .red)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    Button(action: runInstall) {
                        Label("Install", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isRunning || effectiveCommand.isEmpty)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 620, height: 420)
        .onAppear {
            // Pre-fill package name from toolName
            if !toolName.isEmpty { packageInput = toolName }
        }
    }

    // MARK: - Input section

    @ViewBuilder
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(method.rawValue)
                .font(.system(size: 13, weight: .semibold))

            if method == .gitClone {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Repository URL").font(.system(size: 11)).foregroundColor(.secondary)
                    TextField("https://github.com/user/repo", text: $packageInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    Text("Build & install commands (run after clone)").font(.system(size: 11)).foregroundColor(.secondary)
                    TextEditor(text: $buildScript)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 70)
                        .border(Color.secondary.opacity(0.3), width: 1)
                        .cornerRadius(4)
                        .overlay(
                            Group {
                                if buildScript.isEmpty {
                                    Text("make && sudo make install\n# or: go build -o ~/.local/bin/wtf ./...")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 6)
                                        .allowsHitTesting(false)
                                }
                            }, alignment: .topLeading)

                    Text("Binary install path (optional, e.g. ~/.local/bin/wtf)").font(.system(size: 11)).foregroundColor(.secondary)
                    TextField("leave blank to skip cp", text: $installPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
            } else if method == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shell commands to run").font(.system(size: 11)).foregroundColor(.secondary)
                    TextEditor(text: $packageInput)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 110)
                        .border(Color.secondary.opacity(0.3), width: 1)
                        .cornerRadius(4)
                        .overlay(
                            Group {
                                if packageInput.isEmpty {
                                    Text("curl -L https://... -o ~/.local/bin/tool\nchmod +x ~/.local/bin/tool")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 6)
                                        .allowsHitTesting(false)
                                }
                            }, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Package name").font(.system(size: 11)).foregroundColor(.secondary)
                    TextField(method.placeholder, text: $packageInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text("Preview: \(effectiveCommand)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - Log section

    @ViewBuilder
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Output").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                if isRunning {
                    ProgressView().scaleEffect(0.6)
                }
            }
            ScrollView {
                Text(log.isEmpty ? "Ready." : log)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(log.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
        }
    }

    // MARK: - Command building

    private var effectiveCommand: String {
        let pkg = packageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pkg.isEmpty else { return "" }
        switch method {
        case .brew:
            let brewBin = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
                ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
            return "\(brewBin) install \(pkg)"
        case .npm:
            let npm = resolvedBinary("npm", candidates: ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]) ?? "npm"
            return "\(npm) install -g \(pkg)"
        case .pip:
            let pip = resolvedBinary("pip3", candidates: ["/opt/homebrew/bin/pip3", "/usr/local/bin/pip3", "/usr/bin/pip3"]) ?? "pip3"
            return "\(pip) install \(pkg)"
        case .cargo:
            return "\(NSHomeDirectory())/.cargo/bin/cargo install \(pkg)"
        case .goInstall:
            let go = resolvedBinary("go", candidates: ["/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/local/bin/go"]) ?? "go"
            return "\(go) install \(pkg)"
        case .gitClone:
            return "git clone \(pkg)"
        case .custom:
            return pkg
        }
    }

    private func resolvedBinary(_ name: String, candidates: [String]) -> String? {
        candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Run install

    private func runInstall() {
        isRunning = true
        log = ""
        Task {
            let env = buildEnv()
            var lines: [String] = []

            switch method {
            case .gitClone:
                lines = await runGitClone(env: env)
            case .custom:
                lines = await runShellScript(packageInput, env: env)
            default:
                lines = await runSingleCommand(effectiveCommand, env: env)
            }

            let output = lines.joined(separator: "\n")
            let ok = !output.lowercased().contains("error") && !output.lowercased().contains("failed")

            await MainActor.run {
                log = output
                isRunning = false
                finished = true
                success = ok
                if ok {
                    Task {
                        let newPaths = await BinaryWatcherService.resolveWatchPaths()
                        await BinaryWatcherService.shared.scanNow(skipHelpScan: false)
                        _ = newPaths
                        // Re-scan help for this tool
                        await TerminalPackageManager.shared.refreshHelpTextByCommand(toolName)
                        onInstalled?(toolName)
                    }
                }
            }
        }
    }

    private func buildEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/bin", "/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/go/bin",
            "\(NSHomeDirectory())/.local/bin",
            "/usr/local/go/bin"
        ]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + existing.components(separatedBy: ":")).joined(separator: ":")
        return env
    }

    private func runSingleCommand(_ command: String, env: [String: String]) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", command]
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError  = pipe
            guard (try? p.run()) != nil else { return ["Failed to start process"] }
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "").components(separatedBy: .newlines)
        }.value
    }

    private func runShellScript(_ script: String, env: [String: String]) async -> [String] {
        await runSingleCommand(script, env: env)
    }

    private func runGitClone(env: [String: String]) async -> [String] {
        let repoURL = packageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoURL.isEmpty else { return ["No URL provided"] }

        // Clone to a temp dir
        let repoName = URL(string: repoURL)?.lastPathComponent.replacingOccurrences(of: ".git", with: "") ?? "repo"
        let cloneDir = NSTemporaryDirectory() + "ilauncher_build_\(repoName)"
        var lines: [String] = []

        lines += await runSingleCommand("rm -rf \"\(cloneDir)\" && git clone \"\(repoURL)\" \"\(cloneDir)\"", env: env)

        let buildSteps = buildScript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !buildSteps.isEmpty {
            // Run build commands inside the cloned directory
            let cd = "cd \"\(cloneDir)\" && \(buildSteps)"
            lines += await runSingleCommand(cd, env: env)
        }

        // Optionally copy binary
        let dest = installPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dest.isEmpty {
            let expandedDest = dest.replacingOccurrences(of: "~", with: NSHomeDirectory())
            let dir = (expandedDest as NSString).deletingLastPathComponent
            lines += await runSingleCommand("mkdir -p \"\(dir)\" && cp \"\(cloneDir)/\(repoName)\" \"\(expandedDest)\" && chmod +x \"\(expandedDest)\"", env: env)
        }

        return lines
    }
}

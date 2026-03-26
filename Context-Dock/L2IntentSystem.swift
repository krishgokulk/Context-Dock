import Foundation
import SwiftUI
import Combine

// MARK: - L2 Universal Intent System
// One intent = one semantic capability (e.g. MUSIC_PLAYER).
// Multiple packages may satisfy an intent; exactly one is the "default" for that intent.
// When the user says "play some music", L2 looks up MUSIC_PLAYER → ymc → builds the command.

// MARK: - Intent Enum

enum L2ToolIntent: String, CaseIterable, Identifiable, Codable {
    case musicPlayer    = "MUSIC_PLAYER"
    case videoDownload  = "VIDEO_DOWNLOADER"
    case audioDownload  = "AUDIO_DOWNLOADER"
    case fileCompressor = "FILE_COMPRESSOR"
    case imageEditor    = "IMAGE_EDITOR"
    case gitManager     = "GIT_MANAGER"
    case timer          = "TIMER"
    case systemMonitor  = "SYSTEM_MONITOR"
    case packageManager = "PACKAGE_MANAGER"
    case fileDownloader = "FILE_DOWNLOADER"
    case jsonProcessor  = "JSON_PROCESSOR"
    case textEditor     = "TEXT_EDITOR"
    case processManager = "PROCESS_MANAGER"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .musicPlayer:    return "Music Player"
        case .videoDownload:  return "Video Downloader"
        case .audioDownload:  return "Audio Downloader"
        case .fileCompressor: return "File Compressor"
        case .imageEditor:    return "Image Editor"
        case .gitManager:     return "Git Manager"
        case .timer:          return "Timer / Alarm"
        case .systemMonitor:  return "System Monitor"
        case .packageManager: return "Package Manager"
        case .fileDownloader: return "File Downloader"
        case .jsonProcessor:  return "JSON Processor"
        case .textEditor:     return "Text Editor"
        case .processManager: return "Process Manager"
        }
    }

    var icon: String {
        switch self {
        case .musicPlayer:    return "music.note"
        case .videoDownload:  return "play.rectangle.fill"
        case .audioDownload:  return "waveform"
        case .fileCompressor: return "archivebox.fill"
        case .imageEditor:    return "photo.fill"
        case .gitManager:     return "arrow.triangle.branch"
        case .timer:          return "timer"
        case .systemMonitor:  return "chart.bar.fill"
        case .packageManager: return "shippingbox.fill"
        case .fileDownloader: return "arrow.down.circle.fill"
        case .jsonProcessor:  return "curlybraces"
        case .textEditor:     return "doc.text.fill"
        case .processManager: return "cpu"
        }
    }

    /// Keywords in --help / description that suggest a package satisfies this intent.
    var detectionKeywords: [String] {
        switch self {
        case .musicPlayer:
            return ["play", "music", "song", "queue", "playlist", "artist",
                    "ncurses", "tui", "player", "spotify", "track"]
        case .videoDownload:
            return ["youtube", "video", "download", "yt-dlp", "ytdl", "stream", "vimeo", "twitch"]
        case .audioDownload:
            return ["audio", "mp3", "flac", "download", "extract audio", "soundcloud"]
        case .fileCompressor:
            return ["compress", "zip", "tar", "archive", "extract", "decompress", "gzip", "bzip2"]
        case .imageEditor:
            return ["image", "photo", "resize", "convert", "crop", "thumbnail", "jpeg", "png", "webp"]
        case .gitManager:
            return ["git", "commit", "branch", "merge", "push", "clone", "repository", "diff"]
        case .timer:
            return ["timer", "alarm", "countdown", "remind", "schedule", "sleep", "delay", "pomodoro"]
        case .systemMonitor:
            return ["cpu", "memory", "ram", "disk", "process", "htop", "monitor", "top", "uptime"]
        case .packageManager:
            return ["install", "remove", "upgrade", "package", "homebrew", "npm", "pip", "gem"]
        case .fileDownloader:
            return ["download", "wget", "curl", "fetch", "http", "ftp", "transfer"]
        case .jsonProcessor:
            return ["json", "jq", "parse", "format", "query", "filter", "yaml", "toml"]
        case .textEditor:
            return ["edit", "text", "vim", "nano", "editor", "neovim", "helix", "emacs"]
        case .processManager:
            return ["process", "kill", "pid", "signal", "htop", "top", "ps", "pgrep"]
        }
    }

    /// Natural language trigger words the user might say.
    var userTriggers: [String] {
        switch self {
        case .musicPlayer:    return ["play music", "music player", "play song", "play album", "listen to"]
        case .videoDownload:  return ["download video", "download youtube", "download from youtube"]
        case .audioDownload:  return ["download audio", "download mp3", "extract audio", "download music"]
        case .fileCompressor: return ["compress", "zip", "unzip", "extract", "archive"]
        case .imageEditor:    return ["resize image", "convert image", "crop photo", "edit image"]
        case .gitManager:     return ["git status", "git commit", "git push", "git pull", "branch"]
        case .timer:          return ["set timer", "set alarm", "remind me", "pomodoro", "countdown"]
        case .systemMonitor:  return ["system info", "cpu usage", "memory usage", "disk usage", "monitor"]
        case .packageManager: return ["install package", "brew install", "npm install", "pip install"]
        case .fileDownloader: return ["download file", "download from", "wget", "fetch url"]
        case .jsonProcessor:  return ["format json", "parse json", "query json", "process json"]
        case .textEditor:     return ["open editor", "edit file", "vim", "nano"]
        case .processManager: return ["kill process", "find process", "process list", "stop process"]
        }
    }

    /// True if this intent typically involves a TUI / interactive ncurses app.
    var requiresPTY: Bool {
        switch self {
        case .musicPlayer, .textEditor, .processManager, .systemMonitor: return true
        default: return false
        }
    }
}

// MARK: - Intent Conflict

struct IntentConflict: Identifiable {
    let id = UUID()
    let intent: L2ToolIntent
    let candidates: [String] // package command names
    let detectedAt: Date = Date()
}

// MARK: - Intent Registry

@MainActor
class L2IntentRegistry: ObservableObject {
    static let shared = L2IntentRegistry()

    /// intent.rawValue → assigned package command
    @Published var assignments: [String: String] = [:]

    /// Unresolved conflicts (multiple packages for one intent)
    @Published var conflicts: [IntentConflict] = []

    private let storageKey = "L2IntentAssignments"

    init() {
        load()
    }

    // MARK: - Intent Detection

    /// Return the intents a package likely satisfies based on its --help text + description.
    func detectIntents(for package: TerminalPackage) -> [L2ToolIntent] {
        let combined = [
            package.helpText ?? "",
            package.description,
            package.keywords.joined(separator: " "),
            package.name
        ].joined(separator: " ").lowercased()

        return L2ToolIntent.allCases.filter { intent in
            let matches = intent.detectionKeywords.filter { combined.contains($0) }.count
            return matches >= 2
        }
    }

    /// Called after a new tool is added to L2 (e.g. from BinaryWatcherService).
    func autoAssignIntent(for package: TerminalPackage) async {
        let detected = detectIntents(for: package)
        for intent in detected {
            await handleCandidate(package.command, for: intent)
        }
        if !detected.isEmpty {
            print("🎯 [IntentRegistry] '\(package.command)' matched intents: \(detected.map(\.displayName).joined(separator: ", "))")
        }
    }

    private func handleCandidate(_ command: String, for intent: L2ToolIntent) async {
        let current = assignments[intent.rawValue]

        if current == nil {
            // First package for this intent — auto-assign
            assignments[intent.rawValue] = command
            save()
            print("✅ [IntentRegistry] Auto-assigned '\(command)' → \(intent.displayName)")
        } else if current != command {
            // Another package already handles this intent — flag conflict
            let alreadyConflicting = conflicts.contains { $0.intent == intent }
            if !alreadyConflicting {
                let conflict = IntentConflict(intent: intent, candidates: [current!, command])
                conflicts.append(conflict)
                NotificationCenter.default.post(
                    name: .intentConflictDetected,
                    object: nil,
                    userInfo: ["intent": intent.rawValue, "challenger": command]
                )
                print("⚠️ [IntentRegistry] Conflict for \(intent.displayName): '\(current!)' vs '\(command)'")
            }
        }
    }

    // MARK: - Conflict Resolution

    func resolveConflict(_ conflict: IntentConflict, winner: String) {
        assignments[conflict.intent.rawValue] = winner
        conflicts.removeAll { $0.id == conflict.id }
        save()
        print("✅ [IntentRegistry] Resolved conflict for \(conflict.intent.displayName) → '\(winner)'")
    }

    func dismissConflict(_ conflict: IntentConflict) {
        conflicts.removeAll { $0.id == conflict.id }
    }

    // MARK: - Assignment Management

    func setDefault(_ command: String, for intent: L2ToolIntent) {
        assignments[intent.rawValue] = command
        save()
    }

    func clearAssignment(for intent: L2ToolIntent) {
        assignments.removeValue(forKey: intent.rawValue)
        save()
    }

    func defaultPackage(for intent: L2ToolIntent) -> TerminalPackage? {
        guard let command = assignments[intent.rawValue] else { return nil }
        return TerminalPackageManager.shared.packages.first { $0.command == command && $0.isEnabled }
    }

    func assignedCommand(for intent: L2ToolIntent) -> String? {
        assignments[intent.rawValue]
    }

    // MARK: - Query Matching

    /// Given a user query, find the best matching intent and its assigned package.
    func matchIntent(for query: String) -> (intent: L2ToolIntent, package: TerminalPackage)? {
        let queryLower = query.lowercased()

        // Check user trigger phrases first (more specific)
        for intent in L2ToolIntent.allCases {
            for trigger in intent.userTriggers {
                if queryLower.contains(trigger) {
                    if let pkg = defaultPackage(for: intent) {
                        return (intent, pkg)
                    }
                }
            }
        }

        // Fallback: keyword matching
        for intent in L2ToolIntent.allCases {
            let matchCount = intent.detectionKeywords.filter { queryLower.contains($0) }.count
            if matchCount >= 1, let pkg = defaultPackage(for: intent) {
                return (intent, pkg)
            }
        }

        return nil
    }

    /// True if a command for the given query should use a PTY (interactive terminal).
    func requiresPTY(for query: String) -> Bool {
        guard let (intent, _) = matchIntent(for: query) else { return false }
        return intent.requiresPTY
    }

    // MARK: - All Intents with Capability Info

    /// Returns all intents with a list of capable packages (from L2 packages).
    func intentCapabilities() -> [(intent: L2ToolIntent, capable: [TerminalPackage], assigned: String?)] {
        let pm = TerminalPackageManager.shared
        return L2ToolIntent.allCases.map { intent in
            let capable = pm.packages.filter { pkg in
                let matches = detectIntents(for: pkg)
                return matches.contains(intent)
            }
            return (intent, capable, assignments[intent.rawValue])
        }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(assignments) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            assignments = decoded
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let intentConflictDetected = Notification.Name("com.ilauncher.intentConflictDetected")
}

// MARK: - Intent Assignments Settings View

struct IntentAssignmentsView: View {
    @ObservedObject var registry = L2IntentRegistry.shared
    @ObservedObject var pm = TerminalPackageManager.shared
    @State private var showingConflict: IntentConflict?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Conflict warnings
            if !registry.conflicts.isEmpty {
                conflictBanner
            }

            List {
                ForEach(L2ToolIntent.allCases) { intent in
                    IntentRow(intent: intent, registry: registry, pm: pm)
                }
            }
            .listStyle(.inset)
        }
        .sheet(item: $showingConflict) { conflict in
            ConflictResolutionSheet(conflict: conflict)
        }
        .onReceive(NotificationCenter.default.publisher(for: .intentConflictDetected)) { _ in
            showingConflict = registry.conflicts.first
        }
    }

    var conflictBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("\(registry.conflicts.count) intent conflict\(registry.conflicts.count > 1 ? "s" : "") need resolution")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button("Resolve") {
                showingConflict = registry.conflicts.first
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }
}

struct IntentRow: View {
    let intent: L2ToolIntent
    @ObservedObject var registry: L2IntentRegistry
    @ObservedObject var pm: TerminalPackageManager

    var capablePackages: [TerminalPackage] {
        pm.packages.filter { pkg in
            registry.detectIntents(for: pkg).contains(intent)
        }
    }

    var body: some View {
        HStack {
            Image(systemName: intent.icon)
                .frame(width: 22)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(intent.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(intent.userTriggers.prefix(2).joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if intent.requiresPTY {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .help("Requires interactive terminal (PTY)")
            }

            if capablePackages.isEmpty {
                Text("No tool installed")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { registry.assignedCommand(for: intent) ?? "" },
                    set: { newValue in
                        if newValue.isEmpty {
                            registry.clearAssignment(for: intent)
                        } else {
                            registry.setDefault(newValue, for: intent)
                        }
                    }
                )) {
                    Text("None").tag("")
                    ForEach(capablePackages, id: \.command) { pkg in
                        Text(pkg.command).tag(pkg.command)
                    }
                }
                .frame(width: 140)
                .labelsHidden()
            }
        }
        .padding(.vertical, 4)
    }
}

struct ConflictResolutionSheet: View {
    let conflict: IntentConflict
    @ObservedObject var registry = L2IntentRegistry.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text("Intent Conflict")
                        .font(.title3).bold()
                    Text("Which tool should handle \"\(conflict.intent.displayName)\"?")
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            Text("Two tools were detected for the same intent:")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            ForEach(conflict.candidates, id: \.self) { candidate in
                HStack {
                    Image(systemName: "terminal.fill")
                        .foregroundColor(.green)
                    Text(candidate)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Spacer()
                    Button("Use \(candidate)") {
                        registry.resolveConflict(conflict, winner: candidate)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Dismiss") {
                    registry.dismissConflict(conflict)
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

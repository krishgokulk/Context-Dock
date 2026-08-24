// LocalInstallationCheck.swift
// Context-Dock
//
// A local installation question is an inspection task, not an app action. Resolve it
// deterministically before capability matching so the model never mistakes "no adapter"
// for "not installed". Inputs are reduced to executable-name candidates and passed as
// arguments to `which`; no user text is evaluated by a shell.

import Foundation

struct LocalInstallationCheckRequest: Equatable {
    let displayName: String
    let executableNames: [String]
}

struct LocalInstallationCheckResult: Equatable {
    let request: LocalInstallationCheckRequest
    let executablePath: String?
    let indexedPath: String?
    let applicationName: String?
    let applicationPath: String?

    var isInstalled: Bool {
        executablePath != nil || indexedPath != nil || applicationPath != nil
    }

    var trace: [String] {
        var lines = ["Classified request: local installation check"]
        lines.append("Checked executable PATH: \(request.executableNames.joined(separator: ", "))")
        lines.append("Checked DoraX terminal-tool and application inventories")
        lines.append(isInstalled ? "Verified installed location" : "No installed location found")
        return lines
    }

    var answer: String {
        if let executablePath {
            return "**\(request.displayName) is installed.**\n\nExecutable: `\(executablePath)`"
        }
        if let indexedPath {
            return "**\(request.displayName) is installed.**\n\nDoraX terminal-tool inventory: `\(indexedPath)`"
        }
        if let applicationPath {
            return "**\(applicationName ?? request.displayName) is installed.**\n\nApplication: `\(applicationPath)`"
        }
        return "**\(request.displayName) was not found in the locations checked.**\n\n"
            + "I checked executable PATH, DoraX's terminal-tool inventory, and installed applications. "
            + "This means it was not found by those sources; it is not proof that no files with that name exist anywhere on the Mac."
    }

    var receipt: DoraXActionReceipt {
        let output = executablePath ?? indexedPath ?? applicationPath ?? "No installed location found"
        return DoraXActionReceipt(
            command: "inspect_local_installation(\(request.displayName))",
            output: output,
            success: isInstalled,
            isVerification: true)
    }
}

enum LocalInstallationCheck {
    static func parse(_ query: String) -> LocalInstallationCheckRequest? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let patterns = [
            #"(?i)^\s*check\s+(?:if|whether|is)\s+(.+?)\s+is\s+installed(?:\s+on\s+(?:my|this)\s+(?:system|mac|computer))?[?.!]*\s*$"#,
            #"(?i)^\s*(?:is|do\s+i\s+have)\s+(.+?)\s+installed(?:\s+on\s+(?:my|this)\s+(?:system|mac|computer))?[?.!]*\s*$"#,
            #"(?i)^\s*check\s+(.+?)\s+installation(?:\s+on\s+(?:my|this)\s+(?:system|mac|computer))?[?.!]*\s*$"#,
        ]

        var subject: String?
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: trimmed)
            else { continue }
            subject = String(trimmed[capture])
            break
        }
        guard var displayName = subject?.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty
        else { return nil }

        displayName = displayName.replacingOccurrences(
            of: #"(?i)\s+(?:app|application|cli|command|tool|package)$"#,
            with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { return nil }

        let safeWords = displayName.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard !safeWords.isEmpty else { return nil }
        var names: [String] = []
        for candidate in [
            safeWords.joined(),
            safeWords.joined(separator: "-"),
            safeWords.joined(separator: "_"),
        ] where !candidate.isEmpty && !names.contains(candidate) {
            names.append(candidate)
        }
        return LocalInstallationCheckRequest(displayName: displayName, executableNames: names)
    }

    @MainActor
    static func inspect(_ request: LocalInstallationCheckRequest) -> LocalInstallationCheckResult {
        let executablePath = request.executableNames.lazy.compactMap(pathFromWhich).first

        let packages = TerminalPackageManager.shared.packages
        let package = packages.first { package in
            request.executableNames.contains { name in
                package.command.caseInsensitiveCompare(name) == .orderedSame
                    || package.name.caseInsensitiveCompare(name) == .orderedSame
            }
        }
        let indexedPath = package?.installedPath.flatMap {
            FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
        }

        let normalizedDisplay = normalized(request.displayName)
        let application = InstalledApplicationsCatalog.cachedInstalledApps().first {
            normalized($0.name) == normalizedDisplay
        }

        return LocalInstallationCheckResult(
            request: request,
            executablePath: executablePath,
            indexedPath: indexedPath,
            applicationName: application?.name,
            applicationPath: application?.url.path)
    }

    private static func pathFromWhich(_ executable: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [executable]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output, !output.isEmpty, FileManager.default.isExecutableFile(atPath: output)
        else { return nil }
        return output
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

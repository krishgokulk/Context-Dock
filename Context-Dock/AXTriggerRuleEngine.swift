import AppKit

extension AppShortcut {
    func run(type: ActionType, value: String, envVars: [String: String]) {
        switch type {
        case .scriptFile:
            // Run an external script file with context env vars injected
            let expanded = (value as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { return }
            var env = ProcessInfo.processInfo.environment
            for (k, v) in envVars { env[k] = v }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [expanded]
            proc.environment = env
            try? proc.run()

        case .shellCommand:
            var env = ProcessInfo.processInfo.environment
            for (k, v) in envVars { env[k] = v }
            // Resolve {variables} in the command
            var cmd = value
            for (k, v) in envVars { cmd = cmd.replacingOccurrences(of: "{\(k)}", with: v) }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", cmd]
            proc.environment = env
            try? proc.run()

        case .openURL:
            var resolved = value
            for (k, v) in envVars { resolved = resolved.replacingOccurrences(of: "{\(k)}", with: v) }
            if let url = URL(string: resolved) { NSWorkspace.shared.open(url) }

        case .openFile:
            let path = (value as NSString).expandingTildeInPath
            NSWorkspace.shared.open(URL(fileURLWithPath: path))

        case .menuItem:
            var resolved = value
            for (k, v) in envVars { resolved = resolved.replacingOccurrences(of: "{\(k)}", with: v) }
            let path = resolved.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let targetApp = menuTargetApp(from: envVars) else { return }
            // Unified resolver: shortcut → AX click → AppleScript, with notification-based activation
            AXActionResolver.shared.execute(menuPath: path, in: targetApp, envVars: envVars)

        case .appleScript, .jxa:
            var script = value
            for (k, v) in envVars { script = script.replacingOccurrences(of: "{\(k)}", with: v) }
            let lang = type == .jxa ? "JavaScript" : "AppleScript"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = type == .jxa ? ["-l", lang, "-e", script] : ["-e", script]
            try? proc.run()
        }
    }

    private func menuTargetApp(from envVars: [String: String]) -> NSRunningApplication? {
        if let bundleID = envVars["CD_BUNDLE_ID"],
           !bundleID.isEmpty,
           bundleID != Bundle.main.bundleIdentifier,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == bundleID && !$0.isTerminated
           }) {
            return app
        }

        if let previous = AppDelegate.shared?.previousFrontmostApp,
           previous.bundleIdentifier != Bundle.main.bundleIdentifier,
           !previous.isTerminated {
            return previous
        }

        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            return front
        }

        return nil
    }
}

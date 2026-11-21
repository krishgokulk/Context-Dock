import AppKit
import os

@MainActor
enum ProcessUpdateVerifier {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Context-Dock",
        category: "ProcessUpdateVerifier")

    struct RunningAppInfo {
        let app: NSRunningApplication
        let name: String
        let pid: pid_t
    }

    static func runningInstance(bundleID: String) -> RunningAppInfo? {
        guard !bundleID.isEmpty else { return nil }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              !app.isTerminated else { return nil }
        let name = app.localizedName ?? bundleID
        log.notice("process check: \(name, privacy: .public) (pid \(app.processIdentifier)) is running after capability update")
        return RunningAppInfo(app: app, name: name, pid: app.processIdentifier)
    }

    static func restartPromptText(for info: RunningAppInfo) -> String {
        "\(info.name) is currently running. The updated capabilities may not take full effect until the app is restarted. Would you like to quit and relaunch \(info.name)?"
    }

    static func restartApp(_ info: RunningAppInfo) -> Bool {
        let bundleID = info.app.bundleIdentifier ?? ""
        let url = info.app.bundleURL
        info.app.terminate()

        let deadline = Date().addingTimeInterval(5)
        while !info.app.isTerminated, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        guard info.app.isTerminated else {
            log.warning("process restart: \(info.name, privacy: .public) did not terminate in time")
            return false
        }

        if let url {
            NSWorkspace.shared.openApplication(
                at: url, configuration: .init())
            log.notice("process restart: relaunched \(info.name, privacy: .public)")
            return true
        }
        if !bundleID.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(
                at: appURL, configuration: .init())
            log.notice("process restart: relaunched \(info.name, privacy: .public) by bundle id")
            return true
        }
        log.warning("process restart: could not find app to relaunch")
        return false
    }

    /// Returns a human-readable notice when the app is running, nil otherwise.
    static func checkAfterCapabilityUpdate(bundleID: String) -> String? {
        guard let info = runningInstance(bundleID: bundleID) else { return nil }
        return "⚠ \(info.name) is running (pid \(info.pid)). Updated capabilities may require a restart to take full effect."
    }
}

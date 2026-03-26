//
//  APICommandHandler.swift
//  ILauncher
//
//  Central handler for all API commands accessible from extensions
//

import Foundation
import AppKit

class APICommandHandler {
    static let shared = APICommandHandler()

    private init() {}

    /// Main entry point for API commands
    /// Called from extensions via: ilauncher-api <category> <command> [args]
    func handleCommand(_ args: [String]) -> String {
        guard args.count >= 2 else {
            return helpText()
        }

        let category = args[0]
        let commandArgs = Array(args.dropFirst())

        switch category {
        case "media":
            return MediaInfoProvider.shared.handleMediaCommand(commandArgs)

        case "system":
            return handleSystemCommand(commandArgs)

        case "app":
            return handleAppCommand(commandArgs)

        case "notification":
            return handleNotificationCommand(commandArgs)

        case "clipboard":
            return handleClipboardCommand(commandArgs)

        case "screen":
            return handleScreenCommand(commandArgs)

        case "volume":
            return handleVolumeCommand(commandArgs)

        case "brightness":
            return handleBrightnessCommand(commandArgs)

        case "battery":
            return handleBatteryCommand(commandArgs)

        case "network":
            return handleNetworkCommand(commandArgs)

        case "safari":
            return handleSafariCommand(commandArgs)

        case "help":
            return helpText()

        default:
            return "{\"error\": \"Unknown category: \(category)\"}"
        }
    }

    // MARK: - System Commands

    private func handleSystemCommand(_ args: [String]) -> String {
        guard !args.isEmpty else { return "{}" }

        switch args[0] {
        case "hostname":
            return ProcessInfo.processInfo.hostName
        case "os-version":
            return ProcessInfo.processInfo.operatingSystemVersionString
        case "uptime":
            return String(ProcessInfo.processInfo.systemUptime)
        case "cpu-count":
            return String(ProcessInfo.processInfo.processorCount)
        case "memory":
            let memory = ProcessInfo.processInfo.physicalMemory
            return String(memory / 1024 / 1024) // MB
        default:
            return ""
        }
    }

    // MARK: - App Commands

    private func handleAppCommand(_ args: [String]) -> String {
        guard !args.isEmpty else { return "{}" }

        switch args[0] {
        case "frontmost":
            return getFrontmostApp()
        case "running":
            return getRunningApps()
        case "launch":
            if args.count >= 2 {
                launchApp(args[1])
                return "launched"
            }
        default:
            break
        }

        return ""
    }

    private func getFrontmostApp() -> String {
        if let app = NSWorkspace.shared.frontmostApplication {
            let json: [String: Any] = [
                "name": app.localizedName ?? "",
                "bundle": app.bundleIdentifier ?? "",
                "pid": app.processIdentifier
            ]
            if let data = try? JSONSerialization.data(withJSONObject: json),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
        }
        return "{}"
    }

    private func getRunningApps() -> String {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { $0.localizedName ?? "Unknown" }

        if let data = try? JSONSerialization.data(withJSONObject: apps),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "[]"
    }

    private func launchApp(_ bundleId: String) {
        NSWorkspace.shared.launchApplication(withBundleIdentifier: bundleId, options: [], additionalEventParamDescriptor: nil, launchIdentifier: nil)
    }

    // MARK: - Notification Commands

    private func handleNotificationCommand(_ args: [String]) -> String {
        guard args.count >= 2 else { return "" }

        let command = args[0]

        switch command {
        case "send":
            let title = args[1]
            let body = args.count >= 3 ? args[2] : ""
            sendNotification(title: title, body: body)
            return "sent"
        default:
            return ""
        }
    }

    private func sendNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - Clipboard Commands

    private func handleClipboardCommand(_ args: [String]) -> String {
        guard !args.isEmpty else { return "" }

        switch args[0] {
        case "get":
            return NSPasteboard.general.string(forType: .string) ?? ""
        case "set":
            if args.count >= 2 {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(args[1], forType: .string)
                return "set"
            }
        default:
            break
        }

        return ""
    }

    // MARK: - Screen Commands

    private func handleScreenCommand(_ args: [String]) -> String {
        guard !args.isEmpty else { return "{}" }

        switch args[0] {
        case "count":
            return String(NSScreen.screens.count)
        case "main":
            if let main = NSScreen.main {
                let frame = main.frame
                let json: [String: Any] = [
                    "width": frame.width,
                    "height": frame.height,
                    "x": frame.origin.x,
                    "y": frame.origin.y
                ]
                if let data = try? JSONSerialization.data(withJSONObject: json),
                   let string = String(data: data, encoding: .utf8) {
                    return string
                }
            }
        default:
            break
        }

        return "{}"
    }

    // MARK: - Volume Commands

    private func handleVolumeCommand(_ args: [String]) -> String {
        guard !args.isEmpty else { return "" }

        switch args[0] {
        case "get":
            // Would need CoreAudio framework
            return "0"
        case "set":
            // Would need CoreAudio framework
            return ""
        case "mute":
            // Would need CoreAudio framework
            return ""
        case "unmute":
            // Would need CoreAudio framework
            return ""
        default:
            break
        }

        return ""
    }

    // MARK: - Brightness Commands

    private func handleBrightnessCommand(_ args: [String]) -> String {
        // Would need DisplayServices framework
        return ""
    }

    // MARK: - Battery Commands

    private func handleBatteryCommand(_ args: [String]) -> String {
        guard !args.isEmpty else { return "{}" }

        switch args[0] {
        case "level", "percentage":
            return getBatteryLevel()
        case "charging":
            return isCharging() ? "true" : "false"
        case "info":
            return getBatteryInfo()
        default:
            break
        }

        return ""
    }

    private func getBatteryLevel() -> String {
        let script = "pmset -g batt | grep -Eo '\\d+%' | cut -d% -f1"
        return runShellCommand(script) ?? "0"
    }

    private func isCharging() -> Bool {
        let script = "pmset -g batt | grep -q 'AC Power'"
        let result = runShellCommand(script)
        return result != nil
    }

    private func getBatteryInfo() -> String {
        let level = getBatteryLevel()
        let charging = isCharging()

        let json: [String: Any] = [
            "level": Int(level) ?? 0,
            "charging": charging,
            "percentage": level + "%"
        ]

        if let data = try? JSONSerialization.data(withJSONObject: json),
           let string = String(data: data, encoding: .utf8) {
            return string
        }

        return "{}"
    }

    // MARK: - Safari Commands

    private func handleSafariCommand(_ args: [String]) -> String {
        guard !args.isEmpty else { return "{\"error\": \"No command specified\"}" }

        switch args[0] {
        case "save-pdf", "export-pdf":
            let fileName = args.count >= 2 ? args[1] : nil
            let result = SafariAutomation.shared.saveCurrentPageAsPDF(fileName: fileName)

            switch result {
            case .success(let path):
                let json: [String: String] = [
                    "status": "success",
                    "message": "PDF export dialog opened",
                    "path": path
                ]
                if let data = try? JSONSerialization.data(withJSONObject: json),
                   let jsonString = String(data: data, encoding: .utf8) {
                    return jsonString
                }
                return "{\"status\": \"success\"}"

            case .failure(let error):
                return "{\"error\": \"\(error.localizedDescription)\"}"
            }

        case "print":
            let result = SafariAutomation.shared.exportPageAsPDF()

            switch result {
            case .success(let message):
                return "{\"status\": \"success\", \"message\": \"\(message)\"}"
            case .failure(let error):
                return "{\"error\": \"\(error.localizedDescription)\"}"
            }

        case "current-page":
            if let page = SafariAutomation.shared.getCurrentPage() {
                let json: [String: String] = [
                    "title": page.title,
                    "url": page.url
                ]
                if let data = try? JSONSerialization.data(withJSONObject: json),
                   let jsonString = String(data: data, encoding: .utf8) {
                    return jsonString
                }
            }
            return "{\"error\": \"Could not get current page\"}"

        default:
            return "{\"error\": \"Unknown Safari command: \(args[0])\"}"
        }
    }

    // MARK: - Network Commands

    private func handleNetworkCommand(_ args: [String]) -> String {
        guard !args.isEmpty else { return "{}" }

        switch args[0] {
        case "ssid":
            return getCurrentWiFiSSID()
        case "ip":
            return getLocalIP()
        default:
            break
        }

        return ""
    }

    private func getCurrentWiFiSSID() -> String {
        let script = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I | awk '/ SSID/ {print substr($0, index($0, $2))}'"
        return runShellCommand(script) ?? ""
    }

    private func getLocalIP() -> String {
        let script = "ipconfig getifaddr en0"
        return runShellCommand(script) ?? ""
    }

    // MARK: - Helper

    private func runShellCommand(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return output?.isEmpty == false ? output : nil
        } catch {
            return nil
        }
    }

    // MARK: - Help

    private func helpText() -> String {
        return """
        ILauncher API - Available Commands:

        MEDIA:
          ilauncher-api media info          - Get current media info (JSON)
          ilauncher-api media title         - Get track title
          ilauncher-api media artist        - Get artist name
          ilauncher-api media album         - Get album name
          ilauncher-api media state         - Get playback state
          ilauncher-api media play          - Play
          ilauncher-api media pause         - Pause
          ilauncher-api media toggle        - Toggle play/pause
          ilauncher-api media next          - Next track
          ilauncher-api media prev          - Previous track

        SYSTEM:
          ilauncher-api system hostname     - Get hostname
          ilauncher-api system os-version   - Get OS version
          ilauncher-api system uptime       - Get system uptime
          ilauncher-api system cpu-count    - Get CPU count
          ilauncher-api system memory       - Get physical memory (MB)

        APP:
          ilauncher-api app frontmost       - Get frontmost app (JSON)
          ilauncher-api app running         - Get running apps (JSON array)
          ilauncher-api app launch <bundle> - Launch app by bundle ID

        NOTIFICATION:
          ilauncher-api notification send <title> [body]

        CLIPBOARD:
          ilauncher-api clipboard get       - Get clipboard content
          ilauncher-api clipboard set <text>

        SCREEN:
          ilauncher-api screen count        - Get screen count
          ilauncher-api screen main         - Get main screen info (JSON)

        BATTERY:
          ilauncher-api battery level       - Get battery percentage
          ilauncher-api battery charging    - Check if charging
          ilauncher-api battery info        - Get full battery info (JSON)

        NETWORK:
          ilauncher-api network ssid        - Get current WiFi SSID
          ilauncher-api network ip          - Get local IP address

        SAFARI:
          ilauncher-api safari save-pdf [filename] - Save current page as PDF
          ilauncher-api safari print               - Open print dialog for PDF
          ilauncher-api safari current-page        - Get current page info (JSON)
        """
    }
}

//
//  LaunchAtLoginHelper.swift
//  ILauncher
//
//  Helper to manage Launch at Login using ServiceManagement framework
//

import Foundation
import ServiceManagement
import Combine

@available(macOS 13.0, *)
class LaunchAtLoginHelper: ObservableObject {
    static let shared = LaunchAtLoginHelper()

    @Published var isEnabled: Bool = false

    private init() {
        // Check current status on init
        checkStatus()
    }

    /// Check if launch at login is currently enabled
    func checkStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Enable or disable launch at login
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled {
                    #if DEBUG
                    print("✅ Launch at login already enabled")
                    #endif
                } else {
                    try SMAppService.mainApp.register()
                    #if DEBUG
                    print("✅ Launch at login enabled")
                    #endif
                }
            } else {
                if SMAppService.mainApp.status == .notRegistered {
                    #if DEBUG
                    print("✅ Launch at login already disabled")
                    #endif
                } else {
                    try SMAppService.mainApp.unregister()
                    #if DEBUG
                    print("✅ Launch at login disabled")
                    #endif
                }
            }
            isEnabled = enabled
        } catch {
            #if DEBUG
            print("⚠️ Failed to update launch at login status: \(error.localizedDescription)")
            #endif
        }
    }

    /// Toggle launch at login status
    func toggle() {
        setEnabled(!isEnabled)
    }
}

// Fallback for older macOS versions
@available(macOS, deprecated: 13.0, message: "Use LaunchAtLoginHelper for macOS 13+")
class LegacyLaunchAtLoginHelper {
    static let shared = LegacyLaunchAtLoginHelper()

    private let helperBundleIdentifier = "com.ilauncher.helper"

    var isEnabled: Bool {
        // For older macOS, this is a simplified check
        // In production, you'd check login items via LSSharedFileList
        return false
    }

    func setEnabled(_ enabled: Bool) {
        #if DEBUG
        print("⚠️ Launch at login requires macOS 13+")
        #endif
    }
}

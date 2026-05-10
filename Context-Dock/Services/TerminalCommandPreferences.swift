import Foundation

// MARK: - Terminal Command Preferences

/// Stores user preferences for command execution
class TerminalCommandPreferences {
    static let shared = TerminalCommandPreferences()
    
    private init() {}
    
    private let defaults = UserDefaults.standard
    private let autoApproveKey = "terminal_auto_approve_commands"
    private let autoDenyKey = "terminal_auto_deny_commands"
    
    func shouldAutoApprove(_ command: String) -> Bool {
        let approvedCommands = defaults.stringArray(forKey: autoApproveKey) ?? []
        return approvedCommands.contains(command)
    }
    
    func shouldAutoDeny(_ command: String) -> Bool {
        let deniedCommands = defaults.stringArray(forKey: autoDenyKey) ?? []
        return deniedCommands.contains(command)
    }
    
    func addAutoApprove(_ command: String) {
        var approvedCommands = defaults.stringArray(forKey: autoApproveKey) ?? []
        if !approvedCommands.contains(command) {
            approvedCommands.append(command)
            defaults.set(approvedCommands, forKey: autoApproveKey)
        }
    }
    
    func addAutoDeny(_ command: String) {
        var deniedCommands = defaults.stringArray(forKey: autoDenyKey) ?? []
        if !deniedCommands.contains(command) {
            deniedCommands.append(command)
            defaults.set(deniedCommands, forKey: autoDenyKey)
        }
    }
    
    func clearAutoApproved() {
        defaults.removeObject(forKey: autoApproveKey)
    }
    
    func clearAutoDenied() {
        defaults.removeObject(forKey: autoDenyKey)
    }
    
    func getAutoApprovedCommands() -> [String] {
        return defaults.stringArray(forKey: autoApproveKey) ?? []
    }
    
    func getAutoDeniedCommands() -> [String] {
        return defaults.stringArray(forKey: autoDenyKey) ?? []
    }
}

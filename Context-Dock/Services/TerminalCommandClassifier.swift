import Foundation

// MARK: - Command Classification System

/// Classifies terminal commands by risk level for AI-driven execution
class TerminalCommandClassifier {
    static let shared = TerminalCommandClassifier()

    // MARK: - Types

    enum CommandCategory: String, Codable {
        case fileOperation = "File Operation"
        case packageManagement = "Package Management"
        case gitOperation = "Git Operation"
        case systemInfo = "System Info"
        case networkOperation = "Network Operation"
        case processManagement = "Process Management"
        case buildCommand = "Build Command"
        case shellOperation = "Shell Operation"
        case applicationControl = "Application Control"
        case unknown = "Unknown"
    }

    enum RiskLevel: Int, Codable, Comparable {
        case safe = 0       // Auto-execute
        case low = 1        // Auto-execute with notification
        case medium = 2     // Needs approval
        case high = 3       // Needs approval + warning
        case critical = 4   // Blocked

        static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var color: String {
            switch self {
            case .safe, .low: return "green"
            case .medium: return "yellow"
            case .high: return "orange"
            case .critical: return "red"
            }
        }

        var displayName: String {
            switch self {
            case .safe: return "Safe"
            case .low: return "Low Risk"
            case .medium: return "Medium Risk"
            case .high: return "High Risk"
            case .critical: return "Blocked"
            }
        }
    }

    struct CommandClassification {
        let command: String
        let category: CommandCategory
        let riskLevel: RiskLevel
        let explanation: String
        let requiresApproval: Bool
        let blockedReason: String?
        let suggestedAlternative: String?

        var canExecute: Bool {
            riskLevel != .critical
        }

        var shouldAutoExecute: Bool {
            riskLevel == .safe || riskLevel == .low
        }
    }

    // MARK: - Safe Command Patterns (Auto-execute)

    private let safePatterns: [(pattern: String, category: CommandCategory, explanation: String)] = [
        // Read operations
        ("^ls(\\s|$)", .fileOperation, "List directory contents"),
        ("^cat\\s", .fileOperation, "Display file contents"),
        ("^head\\s", .fileOperation, "Show first lines of file"),
        ("^tail\\s", .fileOperation, "Show last lines of file"),
        ("^less\\s", .fileOperation, "View file with pagination"),
        ("^more\\s", .fileOperation, "View file with pagination"),
        ("^find\\s", .fileOperation, "Search for files"),
        ("^grep\\s", .fileOperation, "Search file contents"),
        ("^wc\\s", .fileOperation, "Count lines/words/characters"),
        ("^file\\s", .fileOperation, "Identify file type"),
        ("^stat\\s", .fileOperation, "Display file status"),
        ("^du\\s", .fileOperation, "Show disk usage"),
        ("^df\\s", .systemInfo, "Show disk space"),
        ("^pwd$", .fileOperation, "Print working directory"),
        ("^realpath\\s", .fileOperation, "Show absolute path"),

        // System info
        ("^which\\s", .systemInfo, "Locate a command"),
        ("^whereis\\s", .systemInfo, "Locate command binary"),
        ("^whoami$", .systemInfo, "Show current user"),
        ("^hostname$", .systemInfo, "Show hostname"),
        ("^date$", .systemInfo, "Show current date/time"),
        ("^uptime$", .systemInfo, "Show system uptime"),
        ("^uname\\s", .systemInfo, "Show system information"),
        ("^sw_vers$", .systemInfo, "Show macOS version"),
        ("^system_profiler\\s", .systemInfo, "Show system profile"),
        ("^fastfetch(\\s|$)", .systemInfo, "Show system summary"),
        ("^neofetch(\\s|$)", .systemInfo, "Show system summary"),
        ("^vm_stat$", .systemInfo, "Show VM statistics"),
        ("^sysctl\\s", .systemInfo, "Show system settings"),
        ("^top\\s+-l\\s+1", .systemInfo, "Show process snapshot"),
        ("^ps\\s", .processManagement, "List processes"),
        ("^env$", .systemInfo, "Show environment variables"),
        ("^printenv", .systemInfo, "Print environment variables"),
        ("^echo\\s+\\$", .systemInfo, "Print environment variable"),
        ("^ifconfig(\\s|$)", .networkOperation, "Show network interfaces"),
        ("^ipconfig\\s", .networkOperation, "Show IP configuration"),
        ("^networksetup\\s", .networkOperation, "Show network configuration"),
        ("^netstat\\s", .networkOperation, "Show network statistics"),
        ("^scutil\\s", .networkOperation, "Show network configuration"),
        ("^airport\\s+-I$", .networkOperation, "Show Wi-Fi status"),
        ("^ping\\s+-c\\s+\\d+\\s", .networkOperation, "Ping host (limited)"),
        ("^curl\\s+https?://wttr\\.in", .networkOperation, "Fetch weather info"),
        ("^curl\\s+https?://(ipinfo\\.io|ifconfig\\.me)", .networkOperation, "Fetch network info"),

        // Package info (read-only)
        ("^brew\\s+info\\s", .packageManagement, "Show package information"),
        ("^brew\\s+list", .packageManagement, "List installed packages"),
        ("^brew\\s+search\\s", .packageManagement, "Search for packages"),
        ("^brew\\s+deps\\s", .packageManagement, "Show package dependencies"),
        ("^brew\\s+outdated", .packageManagement, "List outdated packages"),
        ("^brew\\s+--version", .packageManagement, "Show Homebrew version"),
        ("^npm\\s+list", .packageManagement, "List npm packages"),
        ("^npm\\s+view\\s", .packageManagement, "View package info"),
        ("^npm\\s+--version", .packageManagement, "Show npm version"),
        ("^pip\\s+list", .packageManagement, "List pip packages"),
        ("^pip\\s+show\\s", .packageManagement, "Show package info"),
        ("^pip\\s+--version", .packageManagement, "Show pip version"),
        ("^gem\\s+list", .packageManagement, "List Ruby gems"),
        ("^cargo\\s+--version", .packageManagement, "Show Cargo version"),

        // Git read operations
        ("^git\\s+status", .gitOperation, "Show repository status"),
        ("^git\\s+log", .gitOperation, "Show commit history"),
        ("^git\\s+diff(?!.*--cached)", .gitOperation, "Show changes"),
        ("^git\\s+branch(?!\\s+-[dD])", .gitOperation, "List branches"),
        ("^git\\s+remote\\s+-v", .gitOperation, "Show remote URLs"),
        ("^git\\s+show\\s", .gitOperation, "Show commit details"),
        ("^git\\s+tag(?!\\s+-[dD])", .gitOperation, "List tags"),
        ("^git\\s+config\\s+--list", .gitOperation, "List git config"),
        ("^git\\s+rev-parse", .gitOperation, "Parse git references"),
        ("^git\\s+ls-files", .gitOperation, "List tracked files"),
        ("^git\\s+blame\\s", .gitOperation, "Show file annotations"),

        // Safe application commands
        ("^open\\s+-a\\s", .applicationControl, "Open application"),
        ("^open\\s+https?://", .applicationControl, "Open URL in browser"),
        ("^open\\s+\\./?$", .applicationControl, "Open current directory"),

        // Echo for display
        ("^echo\\s+[^>|&$`]+$", .shellOperation, "Display text"),
        ("^printf\\s", .shellOperation, "Format and print text"),

        // Version checks
        ("--version$", .systemInfo, "Check version"),
        ("-v$", .systemInfo, "Check version"),
        ("-V$", .systemInfo, "Check version"),
    ]

    // MARK: - Approval Required Patterns (Medium Risk)

    private let approvalPatterns: [(pattern: String, category: CommandCategory, explanation: String)] = [
        // File modification
        ("^mkdir\\s", .fileOperation, "Create directory"),
        ("^touch\\s", .fileOperation, "Create empty file"),
        ("^cp\\s", .fileOperation, "Copy files"),
        ("^mv\\s", .fileOperation, "Move/rename files"),
        ("^ln\\s", .fileOperation, "Create links"),
        ("^chmod\\s", .fileOperation, "Change permissions"),
        ("^zip\\s", .fileOperation, "Create zip archive"),
        ("^unzip\\s", .fileOperation, "Extract zip archive"),
        ("^tar\\s", .fileOperation, "Archive operations"),
        ("^gzip\\s", .fileOperation, "Compress files"),
        ("^gunzip\\s", .fileOperation, "Decompress files"),

        // Package management
        ("^brew\\s+install\\s", .packageManagement, "Install package via Homebrew"),
        ("^brew\\s+uninstall\\s", .packageManagement, "Uninstall package"),
        ("^brew\\s+upgrade", .packageManagement, "Upgrade packages"),
        ("^brew\\s+update$", .packageManagement, "Update Homebrew"),
        ("^brew\\s+cleanup", .packageManagement, "Clean up old versions"),
        ("^brew\\s+tap\\s", .packageManagement, "Add Homebrew tap"),
        ("^brew\\s+untap\\s", .packageManagement, "Remove Homebrew tap"),
        ("^brew\\s+services\\s+start", .packageManagement, "Start service"),
        ("^brew\\s+services\\s+stop", .packageManagement, "Stop service"),
        ("^brew\\s+services\\s+restart", .packageManagement, "Restart service"),
        ("^npm\\s+install", .packageManagement, "Install npm packages"),
        ("^npm\\s+uninstall", .packageManagement, "Uninstall npm packages"),
        ("^npm\\s+update", .packageManagement, "Update npm packages"),
        ("^npm\\s+init", .packageManagement, "Initialize npm project"),
        ("^npx\\s", .packageManagement, "Run npm package"),
        ("^pip\\s+install", .packageManagement, "Install Python packages"),
        ("^pip\\s+uninstall", .packageManagement, "Uninstall Python packages"),
        ("^gem\\s+install", .packageManagement, "Install Ruby gems"),
        ("^cargo\\s+install", .packageManagement, "Install Rust packages"),
        ("^cargo\\s+build", .buildCommand, "Build Rust project"),

        // Git write operations
        ("^git\\s+add\\s", .gitOperation, "Stage changes"),
        ("^git\\s+commit", .gitOperation, "Commit changes"),
        ("^git\\s+push(?!.*--force)", .gitOperation, "Push to remote"),
        ("^git\\s+pull", .gitOperation, "Pull from remote"),
        ("^git\\s+fetch", .gitOperation, "Fetch from remote"),
        ("^git\\s+checkout\\s", .gitOperation, "Switch branch/restore files"),
        ("^git\\s+switch\\s", .gitOperation, "Switch branches"),
        ("^git\\s+merge\\s", .gitOperation, "Merge branches"),
        ("^git\\s+rebase(?!.*-i)", .gitOperation, "Rebase commits"),
        ("^git\\s+stash", .gitOperation, "Stash changes"),
        ("^git\\s+clone\\s", .gitOperation, "Clone repository"),
        ("^git\\s+init", .gitOperation, "Initialize repository"),
        ("^git\\s+branch\\s+-[dD]", .gitOperation, "Delete branch"),
        ("^git\\s+restore\\s", .gitOperation, "Restore files"),
        ("^git\\s+reset(?!.*--hard)", .gitOperation, "Reset changes"),

        // Build commands
        ("^make(\\s|$)", .buildCommand, "Run Makefile"),
        ("^cmake\\s", .buildCommand, "Configure CMake"),
        ("^swift\\s+build", .buildCommand, "Build Swift project"),
        ("^swift\\s+run", .buildCommand, "Run Swift project"),
        ("^swift\\s+test", .buildCommand, "Test Swift project"),
        ("^xcodebuild\\s", .buildCommand, "Build Xcode project"),
        ("^pod\\s+install", .buildCommand, "Install CocoaPods"),
        ("^bundle\\s+install", .buildCommand, "Install Ruby bundle"),

        // Script execution
        ("^python[3]?\\s", .buildCommand, "Run Python script"),
        ("^node\\s", .buildCommand, "Run Node.js script"),
        ("^ruby\\s", .buildCommand, "Run Ruby script"),
        ("^perl\\s", .buildCommand, "Run Perl script"),
        ("^sh\\s", .shellOperation, "Run shell script"),
        ("^bash\\s", .shellOperation, "Run bash script"),
        ("^zsh\\s", .shellOperation, "Run zsh script"),

        // Process management
        ("^kill\\s+-[0-9]+\\s", .processManagement, "Send signal to process"),
        ("^killall\\s", .processManagement, "Kill processes by name"),
        ("^pkill\\s", .processManagement, "Kill processes by pattern"),

        // Network
        ("^curl\\s+(?!.*\\|)", .networkOperation, "Fetch URL"),
        ("^wget\\s+(?!.*\\|)", .networkOperation, "Download file"),
        ("^ping\\s", .networkOperation, "Ping host"),
        ("^traceroute\\s", .networkOperation, "Trace route"),
        ("^nslookup\\s", .networkOperation, "DNS lookup"),
        ("^dig\\s", .networkOperation, "DNS query"),
        ("^host\\s", .networkOperation, "DNS lookup"),

        // File deletion (single files, not recursive)
        ("^rm\\s+[^-]", .fileOperation, "Remove file"),
        ("^rm\\s+-[if]\\s", .fileOperation, "Remove file interactively"),
        ("^rmdir\\s", .fileOperation, "Remove empty directory"),
    ]

    // MARK: - Blocked Patterns (Critical Risk)

    private let blockedPatterns: [(pattern: String, reason: String, alternative: String?)] = [
        // Recursive deletion
        ("rm\\s+(-rf|-fr|--recursive.*--force|--force.*--recursive)",
         "Recursive forced deletion can cause irreversible data loss",
         "Use rm -i for interactive deletion, or Finder for safer file management"),

        ("rm\\s+.*\\s+/$",
         "Deleting root directory would destroy the system",
         nil),

        ("rm\\s+.*~",
         "Deleting home directory would destroy all user data",
         nil),

        ("rm\\s+.*\\*",
         "Wildcard deletion is dangerous without review",
         "List files first with ls, then delete specific files"),

        // Privilege escalation
        ("^sudo\\s",
         "Administrator commands require explicit user action in Terminal.app",
         "Run the command manually in Terminal if you need admin access"),

        ("^su\\s",
         "Switching users requires explicit authentication",
         nil),

        // System modification
        ("^chown\\s",
         "Changing file ownership can break system files",
         nil),

        ("^chmod\\s+.*-[rR]|^chmod\\s+-[rR]",
         "Recursive permission changes can make files inaccessible",
         "Review affected files and change permissions individually"),

        ("^chgrp\\s",
         "Changing file group can affect permissions",
         nil),

        // Dangerous piping
        ("curl.*\\|.*bash",
         "Piping remote content to bash is a security risk",
         "Download the script first, review it, then run manually"),

        ("curl.*\\|.*sh",
         "Piping remote content to shell is a security risk",
         "Download the script first, review it, then run manually"),

        ("wget.*\\|.*bash",
         "Piping downloaded content to bash is a security risk",
         "Download the script first, review it, then run manually"),

        ("wget.*\\|.*sh",
         "Piping downloaded content to shell is a security risk",
         "Download the script first, review it, then run manually"),

        // Remote access
        ("^ssh\\s",
         "SSH connections should be initiated manually for security",
         "Open Terminal.app and run SSH command directly"),

        ("^scp\\s",
         "Secure copy should be initiated manually",
         "Open Terminal.app and run SCP command directly"),

        ("^rsync\\s+.*@",
         "Remote sync should be initiated manually",
         nil),

        // Disk operations
        ("^dd\\s",
         "dd can overwrite disks and cause data loss",
         "Use Disk Utility for disk operations"),

        ("^diskutil\\s+(erase|partition|mount|unmount|apfs)",
         "Disk modification requires explicit user action",
         "Use Disk Utility for disk management"),

        ("^mkfs",
         "Creating filesystems can destroy data",
         nil),

        // Dangerous git operations
        ("^git\\s+push.*--force",
         "Force push can overwrite remote history",
         "Use git push without --force, or run manually if needed"),

        ("^git\\s+reset.*--hard",
         "Hard reset discards all uncommitted changes",
         "Use git stash to save changes first"),

        ("^git\\s+rebase\\s+-i",
         "Interactive rebase should be done manually",
         "Run git rebase -i in Terminal directly"),

        ("^git\\s+clean\\s+-fd",
         "Cleaning untracked files is irreversible",
         "Use git clean -n to preview first"),

        // Shell modification
        ("^export\\s+PATH=",
         "Modifying PATH could break the shell environment",
         nil),

        ("^unset\\s",
         "Unsetting variables could break the environment",
         nil),

        // Code execution
        ("^eval\\s",
         "eval can execute arbitrary code",
         nil),

        ("^exec\\s",
         "exec replaces the current process",
         nil),

        ("^source\\s",
         "Sourcing scripts can modify the environment",
         "Review the script manually before sourcing"),

        // Destructive macOS commands
        ("^defaults\\s+delete",
         "Deleting defaults can break applications",
         nil),

        ("^launchctl\\s+unload",
         "Unloading launch agents can break services",
         nil),

        ("^csrutil\\s",
         "System Integrity Protection changes require Recovery Mode",
         nil),
    ]

    // MARK: - Classification

    func classify(_ command: String) -> CommandClassification {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check blocked patterns first
        for (pattern, reason, alternative) in blockedPatterns {
            if matches(trimmedCommand, pattern: pattern) {
                return CommandClassification(
                    command: trimmedCommand,
                    category: categorize(trimmedCommand),
                    riskLevel: .critical,
                    explanation: reason,
                    requiresApproval: true,
                    blockedReason: reason,
                    suggestedAlternative: alternative
                )
            }
        }

        // Check safe patterns
        for (pattern, category, explanation) in safePatterns {
            if matches(trimmedCommand, pattern: pattern) {
                return CommandClassification(
                    command: trimmedCommand,
                    category: category,
                    riskLevel: .safe,
                    explanation: explanation,
                    requiresApproval: false,
                    blockedReason: nil,
                    suggestedAlternative: nil
                )
            }
        }

        // Check approval patterns
        for (pattern, category, explanation) in approvalPatterns {
            if matches(trimmedCommand, pattern: pattern) {
                return CommandClassification(
                    command: trimmedCommand,
                    category: category,
                    riskLevel: .medium,
                    explanation: explanation,
                    requiresApproval: true,
                    blockedReason: nil,
                    suggestedAlternative: nil
                )
            }
        }

        // Unknown command - require approval
        return CommandClassification(
            command: trimmedCommand,
            category: categorize(trimmedCommand),
            riskLevel: .high,
            explanation: "Unknown command - review before execution",
            requiresApproval: true,
            blockedReason: nil,
            suggestedAlternative: nil
        )
    }

    // MARK: - Helpers

    private func matches(_ command: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(command.startIndex..., in: command)
        return regex.firstMatch(in: command, options: [], range: range) != nil
    }

    private func categorize(_ command: String) -> CommandCategory {
        let firstWord = command.split(separator: " ").first?.lowercased() ?? ""

        switch firstWord {
        case "ls", "cat", "head", "tail", "find", "grep", "cp", "mv", "rm", "mkdir", "touch", "chmod", "zip", "unzip", "tar":
            return .fileOperation
        case "brew", "npm", "npx", "pip", "gem", "cargo", "pod", "bundle":
            return .packageManagement
        case "git":
            return .gitOperation
        case "ps", "top", "kill", "killall", "pkill":
            return .processManagement
        case "curl", "wget", "ping", "ssh", "scp":
            return .networkOperation
        case "make", "cmake", "swift", "xcodebuild", "python", "python3", "node", "ruby":
            return .buildCommand
        case "open":
            return .applicationControl
        case "which", "whereis", "whoami", "hostname", "date", "uptime", "uname", "sw_vers", "df", "du":
            return .systemInfo
        default:
            return .unknown
        }
    }
}

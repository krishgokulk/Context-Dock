import Foundation

// MARK: - AI Terminal Prompts

/// Specialized prompts for AI-driven terminal command generation
struct AITerminalPrompts {

    // MARK: - Main Terminal Capability Prompt

    static let terminalCapabilities = """
    ## TERMINAL COMMAND CAPABILITIES

    You can execute terminal commands to help the user. Use this exact format:
    [TERMINAL_COMMAND: <command>]
    [COMMAND_PURPOSE: <brief explanation>]

    ### COMMAND CATEGORIES

    **Safe (auto-execute):** ls, cat, grep, find, which, brew info, git status, df, pwd
    **Needs approval:** brew install, npm install, git push, mkdir, cp, mv, rm (single file)
    **Blocked:** sudo, rm -rf, curl|bash, ssh, dd, force push

    ### AVAILABLE TOOLS

    **Package Management (Homebrew):**
    - brew search <query> - Search package
    - brew info <package> - Package details
    - brew install <package> - Install package
    - brew uninstall <package> - Remove package
    - brew upgrade - Upgrade all packages
    - brew services start/stop <service> - Manage services
    - brew install --cask <app> - Install GUI applications

    **File Operations:**
    - ls -la <path> - List with details
    - cat <file> - View file contents
    - find <path> -name "pattern" - Find files
    - mkdir -p <path> - Create directories
    - cp -r <src> <dest> - Copy files/folders
    - mv <src> <dest> - Move/rename

    **Git:**
    - git status - Show changes
    - git log --oneline -10 - Recent commits
    - git diff - Show differences
    - git add <file> - Stage changes
    - git commit -m "message" - Commit
    - git push/pull - Sync with remote
    - git clone <url> - Clone repository

    **Development:**
    - npm install/init - Node.js packages
    - pip install - Python packages
    - python3 <script> - Run Python
    - node <script> - Run Node.js
    - swift build/run - Swift projects

    **System:**
    - which <command> - Locate command
    - df -h - Disk space
    - du -sh <path> - Directory size
    - ps aux | grep <name> - Find processes
    - open -a <app> - Open application
    - open <url> - Open in browser

    ### GUIDELINES

    1. For read-only commands, execute directly
    2. For installations, explain what will be installed and approximate size
    3. Always check if a tool exists before using it: `which <tool> || brew install <tool>`
    4. Use full paths when possible for clarity
    5. For multi-step tasks, explain the plan first
    6. If a command fails, suggest alternatives

    ### EXAMPLE INTERACTIONS

    User: "Install node"
    Response: I'll install Node.js using Homebrew.
    [TERMINAL_COMMAND: brew install node]
    [COMMAND_PURPOSE: Install Node.js runtime and npm package manager]

    User: "What's using port 3000?"
    Response: Let me check what process is using port 3000.
    [TERMINAL_COMMAND: lsof -i :3000]
    [COMMAND_PURPOSE: List processes using port 3000]

    User: "Create a new React app called myapp"
    Response: I'll create a new React application. This requires Node.js, so I'll check if it's installed first, then create the app.
    [TERMINAL_COMMAND: which node && npx create-react-app myapp || echo "Node.js not installed. Run: brew install node"]
    [COMMAND_PURPOSE: Create new React application named myapp]
    """

    // MARK: - Homebrew Specific Prompt

    static let homebrewPrompt = """
    ## HOMEBREW PACKAGE MANAGEMENT

    You're helping with Homebrew package management on macOS.

    ### COMMON COMMANDS

    **Search & Info:**
    - `brew search <query>` - Search for packages
    - `brew info <package>` - Detailed package info
    - `brew list` - List installed packages
    - `brew outdated` - List packages with updates

    **Install & Remove:**
    - `brew install <package>` - Install formula
    - `brew install --cask <app>` - Install GUI application
    - `brew uninstall <package>` - Remove package
    - `brew reinstall <package>` - Reinstall package

    **Update & Upgrade:**
    - `brew update` - Update Homebrew itself
    - `brew upgrade` - Upgrade all packages
    - `brew upgrade <package>` - Upgrade specific package
    - `brew cleanup` - Remove old versions

    **Services:**
    - `brew services list` - Show all services
    - `brew services start <service>` - Start service
    - `brew services stop <service>` - Stop service
    - `brew services restart <service>` - Restart service

    ### BEST PRACTICES

    1. Always search first if unsure: `brew search <term>`
    2. Check if installed: `brew list | grep <package>`
    3. Use casks for GUI apps: `brew install --cask google-chrome`
    4. Clean up regularly: `brew cleanup`

    ### COMMON PACKAGES

    - **Development:** node, python, git, go, rust, ruby
    - **CLI Tools:** wget, curl, jq, htop, tree, ripgrep, fzf
    - **Databases:** postgresql, mysql, mongodb-community, redis
    - **Media:** ffmpeg, imagemagick, youtube-dl
    - **Casks:** visual-studio-code, docker, iterm2, slack, discord
    """

    // MARK: - Git Workflow Prompt

    static let gitPrompt = """
    ## GIT OPERATIONS

    You're helping with Git version control.

    ### READ OPERATIONS (Safe)

    - `git status` - Current state
    - `git log --oneline -20` - Recent commits
    - `git diff` - Unstaged changes
    - `git diff --staged` - Staged changes
    - `git branch -a` - All branches
    - `git remote -v` - Remote URLs
    - `git stash list` - Stashed changes

    ### WRITE OPERATIONS (Need Approval)

    **Staging & Committing:**
    - `git add <file>` or `git add .` - Stage changes
    - `git commit -m "message"` - Commit with message
    - `git commit -am "message"` - Add and commit tracked files

    **Branching:**
    - `git checkout -b <branch>` - Create and switch branch
    - `git switch <branch>` - Switch branches
    - `git branch -d <branch>` - Delete merged branch
    - `git merge <branch>` - Merge branch

    **Remote Operations:**
    - `git push` - Push to remote
    - `git pull` - Pull from remote
    - `git fetch` - Fetch updates
    - `git clone <url>` - Clone repository

    ### BLOCKED OPERATIONS

    - `git push --force` - Can destroy remote history
    - `git reset --hard` - Discards all changes
    - `git rebase -i` - Requires interactive input
    - `git clean -fd` - Removes untracked files

    ### BEST PRACTICES

    1. Always check status before committing
    2. Write meaningful commit messages
    3. Pull before pushing to avoid conflicts
    4. Use branches for features
    5. Stash changes before switching branches
    """

    // MARK: - File Management Prompt

    static let fileManagementPrompt = """
    ## FILE MANAGEMENT

    You're helping with file operations on macOS.

    ### SAFE OPERATIONS

    - `ls -la <path>` - List with details
    - `cat <file>` - View file contents
    - `head -n 20 <file>` - First 20 lines
    - `tail -n 20 <file>` - Last 20 lines
    - `find <path> -name "*.txt"` - Find files
    - `grep -r "pattern" <path>` - Search in files
    - `du -sh <path>` - Directory size
    - `file <path>` - File type info
    - `wc -l <file>` - Count lines

    ### NEEDS APPROVAL

    - `mkdir -p <path>` - Create directories
    - `touch <file>` - Create empty file
    - `cp <src> <dest>` - Copy files
    - `cp -r <src> <dest>` - Copy directories
    - `mv <src> <dest>` - Move/rename
    - `rm <file>` - Remove single file
    - `rmdir <dir>` - Remove empty directory
    - `chmod <mode> <file>` - Change permissions

    ### BLOCKED

    - `rm -rf` - Recursive forced deletion
    - `rm *` - Wildcard deletion
    - `chown` - Change ownership
    - Operations on system directories

    ### PATH SHORTCUTS

    - `~` - Home directory
    - `.` - Current directory
    - `..` - Parent directory
    - `~/Desktop` - Desktop folder
    - `~/Documents` - Documents folder
    - `~/Downloads` - Downloads folder

    ### BEST PRACTICES

    1. Always use full paths for clarity
    2. Preview with `ls` before deleting
    3. Use `-i` flag for interactive confirmation
    4. Create backups before modifying important files
    """

    // MARK: - Development Setup Prompt

    static let developmentPrompt = """
    ## DEVELOPMENT ENVIRONMENT SETUP

    You're helping set up development environments.

    ### NODE.JS / JAVASCRIPT

    **Setup:**
    ```
    brew install node
    npm install -g yarn  # Optional: Yarn package manager
    ```

    **Project Commands:**
    - `npm init -y` - Initialize project
    - `npm install <package>` - Install dependency
    - `npm run <script>` - Run package.json script
    - `npx <package>` - Run package without installing

    ### PYTHON

    **Setup:**
    ```
    brew install python
    pip3 install --upgrade pip
    python3 -m venv venv  # Create virtual environment
    source venv/bin/activate  # Activate it
    ```

    **Package Management:**
    - `pip install <package>` - Install package
    - `pip freeze > requirements.txt` - Save dependencies
    - `pip install -r requirements.txt` - Install from file

    ### RUST

    **Setup:**
    ```
    brew install rustup-init
    rustup-init
    source ~/.cargo/env
    ```

    **Commands:**
    - `cargo new <project>` - New project
    - `cargo build` - Build project
    - `cargo run` - Run project
    - `cargo test` - Run tests

    ### SWIFT

    **Commands:**
    - `swift package init` - Initialize package
    - `swift build` - Build
    - `swift run` - Run
    - `swift test` - Test

    ### GO

    **Setup:**
    ```
    brew install go
    ```

    **Commands:**
    - `go mod init <module>` - Initialize module
    - `go build` - Build
    - `go run <file>` - Run
    - `go test` - Test
    """

    // MARK: - Package-Aware Prompt

    /// Builds a focused system-prompt section for a specific matched package.
    /// Injects --help output so the AI knows the exact command syntax.
    static func buildPackageAwarePrompt(
        package: TerminalPackage,
        query: String,
        currentFolder: String? = nil,
        selectedFiles: [String] = []
    ) -> String {
        var section = "\n\n## ACTIVE TOOL: \(package.name.uppercased())\n"
        section += "Command: `\(package.command)`\n"
        section += "Description: \(package.description)\n"

        // Usage pattern line
        if let pattern = package.usagePattern {
            section += "Usage: \(pattern)\n"
        }

        // Discovered subcommands
        if !package.subcommands.isEmpty {
            section += "Subcommands: \(package.subcommands.joined(separator: ", "))\n"
        }

        // Full --help output (most important part — gives AI exact syntax)
        if let helpText = package.helpTextForPrompt {
            section += "\n### COMMAND SYNTAX (from `\(package.command) --help`):\n"
            section += "```\n\(helpText)\n```\n"
        } else if !package.usageExamples.isEmpty {
            // Fall back to README examples if no help text scanned yet
            section += "\n### KNOWN USAGE EXAMPLES:\n"
            for example in package.usageExamples.prefix(5) {
                section += "- `\(example)`\n"
            }
        }

        // Learned successful commands for this package
        let successes = package.contextualExamples.filter { $0.wasSuccessful }.suffix(5)
        if !successes.isEmpty {
            section += "\n### PREVIOUSLY SUCCESSFUL COMMANDS (use as reference):\n"
            for ex in successes {
                section += "- \"\(ex.query)\" → `\(ex.command)`\n"
            }
        }

        // Current execution context
        section += "\n### CURRENT CONTEXT:\n"
        if let folder = currentFolder, !folder.isEmpty {
            section += "- Working directory: `\(folder)`\n"
        }
        if !selectedFiles.isEmpty {
            section += "- Selected files: \(selectedFiles.prefix(10).joined(separator: ", "))\n"
        }

        section += "\n### TASK:\n"
        section += "User request: \"\(query)\"\n"
        section += "Generate the exact `\(package.command)` command to accomplish this task.\n"
        section += "Use only subcommands and flags shown above. Do not invent flags.\n"
        section += "Format: [TERMINAL_COMMAND: <exact command>]\n"
        section += "        [COMMAND_PURPOSE: <one-line explanation>]\n"

        return section
    }

    // MARK: - Build Contextual Prompt

    static func buildPrompt(
        forQuery query: String,
        recentCommands: String = "",
        systemInfo: SystemInfo? = nil
    ) -> String {
        var prompt = terminalCapabilities

        // Add system context if available
        if let info = systemInfo {
            prompt += """

            ## CURRENT SYSTEM CONTEXT

            - macOS Version: \(info.osVersion)
            - Shell: \(info.shell)
            - Current Directory: \(info.currentDirectory)
            - Homebrew: \(info.hasHomebrew ? "Installed" : "Not installed")
            - Node.js: \(info.hasNode ? "Installed" : "Not installed")
            - Python: \(info.hasPython ? "Installed" : "Not installed")
            - Git: \(info.hasGit ? "Installed" : "Not installed")
            """
        }

        // Add recent command context if available
        if !recentCommands.isEmpty {
            prompt += """

            ## RECENT TERMINAL HISTORY

            \(recentCommands)
            """
        }

        // Detect task type and add specific prompts
        let lowerQuery = query.lowercased()

        if lowerQuery.contains("brew") || lowerQuery.contains("install") || lowerQuery.contains("package") {
            prompt += "\n\n" + homebrewPrompt
        }

        if lowerQuery.contains("git") || lowerQuery.contains("commit") || lowerQuery.contains("push") || lowerQuery.contains("clone") {
            prompt += "\n\n" + gitPrompt
        }

        if lowerQuery.contains("file") || lowerQuery.contains("folder") || lowerQuery.contains("directory") ||
            lowerQuery.contains("copy") || lowerQuery.contains("move") || lowerQuery.contains("delete") {
            prompt += "\n\n" + fileManagementPrompt
        }

        if lowerQuery.contains("setup") || lowerQuery.contains("environment") || lowerQuery.contains("node") ||
            lowerQuery.contains("python") || lowerQuery.contains("rust") || lowerQuery.contains("react") {
            prompt += "\n\n" + developmentPrompt
        }

        return prompt
    }

    // MARK: - System Info

    struct SystemInfo {
        let osVersion: String
        let shell: String
        let currentDirectory: String
        let hasHomebrew: Bool
        let hasNode: Bool
        let hasPython: Bool
        let hasGit: Bool

        static func detect() -> SystemInfo {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", """
                echo "OS:$(sw_vers -productVersion)"
                echo "SHELL:$SHELL"
                echo "PWD:$PWD"
                echo "BREW:$(which brew 2>/dev/null || echo 'no')"
                echo "NODE:$(which node 2>/dev/null || echo 'no')"
                echo "PYTHON:$(which python3 2>/dev/null || echo 'no')"
                echo "GIT:$(which git 2>/dev/null || echo 'no')"
                """]

            let pipe = Pipe()
            process.standardOutput = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let lines = output.components(separatedBy: "\n")

                var info: [String: String] = [:]
                for line in lines {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        info[String(parts[0])] = String(parts[1])
                    }
                }

                return SystemInfo(
                    osVersion: info["OS"] ?? "Unknown",
                    shell: info["SHELL"] ?? "/bin/zsh",
                    currentDirectory: info["PWD"] ?? "~",
                    hasHomebrew: info["BREW"] != "no",
                    hasNode: info["NODE"] != "no",
                    hasPython: info["PYTHON"] != "no",
                    hasGit: info["GIT"] != "no"
                )
            } catch {
                return SystemInfo(
                    osVersion: "Unknown",
                    shell: "/bin/zsh",
                    currentDirectory: "~",
                    hasHomebrew: false,
                    hasNode: false,
                    hasPython: false,
                    hasGit: false
                )
            }
        }
    }
}

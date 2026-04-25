# L2 GitHub Tool Integration

## Overview

L2 can now intelligently handle GitHub repository URLs. When you paste a GitHub link, L2 will:

1. **Analyze** the repository (README, releases, metadata)
2. **Detect** installation methods (Homebrew, Cargo, npm, etc.)
3. **Assess risk** based on popularity and install method
4. **Install** the tool with user approval
5. **Register** it for future L2 tasks

## Quick Start

### Example Usage

```
You: https://github.com/sunboylabs/scmd

L2: ## 📦 scmd

| Property | Value |
|----------|-------|
| **Repository** | sunboylabs/scmd |
| **Language** | Rust |
| **Stars** | ⭐ 256 |
| **Status** | ⬇️ Not installed |

### 🛠 Capabilities
- search
- execute
- filter

### 💻 Installation
**Recommended method:** Homebrew
```bash
brew install scmd
```

[Install] [Open in Browser] [Copy Command]
```

### Natural Language Examples

```
"Install https://github.com/BurntSushi/ripgrep"
→ Analyzes and offers to install ripgrep

"What is https://github.com/sharkdp/fd"
→ Shows analysis without auto-installing

"Add this tool github.com/junegunn/fzf"
→ Detects install intent, shows installation options
```

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────┐
│                    User Query with GitHub URL                │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    L2GitHubBridge                            │
│  - Detects GitHub URLs in queries                           │
│  - Routes to GitHubToolManager                              │
│  - Converts response to L2Response format                   │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                  GitHubToolManager                           │
│  - Fetches repository info via GitHub API                   │
│  - Parses README for install instructions                   │
│  - Detects capabilities via keyword analysis                │
│  - Manages tool installation via TerminalAIBridge           │
│  - Caches discovered tools                                  │
└──────────────────────────┬──────────────────────────────────┘
                           │
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
    ┌────────────┐  ┌────────────┐  ┌────────────┐
    │ GitHub API │  │ Terminal   │  │ Tool       │
    │            │  │ AIBridge   │  │ Registry   │
    └────────────┘  └────────────┘  └────────────┘
```

### Data Models

#### GitHubTool
```swift
struct GitHubTool {
    let name: String              // "ripgrep"
    let fullName: String          // "BurntSushi/ripgrep"
    let description: String
    let repositoryURL: URL
    let language: String?         // "Rust"
    let topics: [String]          // ["cli", "search", "grep"]
    let stars: Int
    let latestRelease: GitHubRelease?
    let installMethods: [InstallMethod]  // [.homebrew, .cargo]
    let capabilities: [String]    // AI-detected capabilities
    var isInstalled: Bool
    var installedPath: String?
}
```

#### Install Methods
```swift
enum InstallMethod {
    case homebrew    // brew install <name>
    case cargo       // cargo install <name>
    case npm         // npm install -g <name>
    case pip         // pip3 install <name>
    case go          // go install <repo>@latest
    case gitClone    // git clone && make install
    case binary      // Download pre-built binary
    case script      // curl | bash (least preferred)
}
```

## Features

### 1. Automatic URL Detection

L2 automatically detects GitHub URLs in any format:
- `https://github.com/owner/repo`
- `github.com/owner/repo`
- URLs with paths like `/tree/main` or `/blob/...`

### 2. README Parsing

Extracts from README:
- Installation instructions (code blocks in "Install" sections)
- Usage examples
- Dependencies
- Capabilities (from feature lists)

### 3. Install Method Detection

Scans README for keywords:
| Method | Detection Keywords |
|--------|-------------------|
| Homebrew | `brew install`, `homebrew` |
| Cargo | `cargo install`, `Cargo.toml` |
| npm | `npm install`, `package.json` |
| pip | `pip install`, `setup.py` |
| Go | `go install`, `go.mod` |

### 4. Risk Assessment

Evaluates installation risk:

| Level | Criteria |
|-------|----------|
| **Low** | 1000+ stars, package manager install |
| **Medium** | 50-1000 stars, trusted method |
| **High** | <50 stars, binary/script install |

### 5. Safe Installation

All installations go through `TerminalAIBridge`:
- Shows approval dialog
- Displays full command
- Shows risk level
- Allows editing command
- Logs to audit trail

### 6. Tool Registry

Discovered tools are cached and available for:
- Future L2 task execution
- Settings management
- Capability lookup

## Integration Points

### With L2UnifiedAssistant

```swift
// In L2UnifiedAssistant.process()
if let response = await handleGitHubURL(in: query) {
    return response
}
```

### With L2AITaskExecutor

```swift
// When planning a task, check GitHub tools
let githubTools = GitHubToolManager.shared.getInstalledTools()
for tool in githubTools {
    if tool.capabilities.contains(taskRequirement) {
        // Suggest using this tool
    }
}
```

### With TerminalAIBridge

```swift
// Installation uses existing approval workflow
let (success, output) = await TerminalAIBridge.shared.processAICommand(
    "brew install \(tool.name)",
    purpose: "Install \(tool.name) from GitHub"
)
```

## UI Components

### GitHubToolAnalysisView
Full analysis view with:
- Repository metadata
- Capabilities list
- Install method selector
- Risk assessment
- Install button

### GitHubToolCard
Compact card for inline display in L2 responses.

### GitHubURLDetectedBanner
Inline banner when URL is detected in input.

### GitHubToolsSettingsView
Settings panel for managing discovered tools.

## API Rate Limits

GitHub API limits:
- **Unauthenticated**: 60 requests/hour
- **Authenticated**: 5,000 requests/hour

To increase limits, set a GitHub token:
```swift
GitHubToolManager.shared.githubToken = "ghp_..."
```

## Security Considerations

### Blocked Patterns

L2 will warn about risky installations:
- `curl | bash` scripts (highest risk)
- Binary downloads without checksums
- Repositories with very few stars

### Approval Required

All installations require explicit user approval:
1. Medium risk → Standard approval dialog
2. High risk → Warning + approval dialog
3. Package managers → Trusted but still approved

### Audit Logging

All GitHub tool installations are logged to:
`~/Library/Logs/ILauncher/terminal_audit.log`

## Future Enhancements

### Planned Features

1. **GitHub Token Management**
   - Secure storage of personal access token
   - Higher API rate limits

2. **Tool Updates**
   - Check for new releases
   - Offer updates for installed tools

3. **Capability Learning**
   - AI-powered capability extraction
   - Learn from tool usage patterns

4. **Extension Generation**
   - Auto-generate L2 extensions from installed tools
   - Map tool commands to natural language

5. **Tool Recommendations**
   - Suggest tools based on user's tasks
   - "Users who installed X also installed Y"

## Files

| File | Purpose |
|------|---------|
| `L2GitHubToolIntegration.swift` | Core manager, API, models |
| `GitHubToolView.swift` | SwiftUI views for display |
| `L2GitHubBridge.swift` | L2 integration layer |

## Example Workflow

```
1. User pastes: "install https://github.com/sharkdp/bat"

2. L2GitHubBridge.shouldHandle() → true

3. GitHubToolManager.analyzeRepository()
   - Fetch /repos/sharkdp/bat
   - Fetch /repos/sharkdp/bat/readme
   - Fetch /repos/sharkdp/bat/releases/latest
   - Parse README → detect brew, cargo
   - Analyze capabilities → ["cat", "syntax highlighting", "git integration"]

4. Build GitHubAnalysis
   - suggestedMethod: .homebrew
   - command: "brew install bat"
   - riskLevel: .low (50k+ stars)

5. Return L2Response with analysis + actions

6. User clicks "Install via Homebrew"

7. TerminalAIBridge.processAICommand("brew install bat")
   - Show approval dialog
   - Execute command
   - Wait for completion

8. GitHubToolManager.registerWithL2()
   - Mark as installed
   - Save to registry
   - Available for future tasks

9. User can now ask: "Use bat to show my code with syntax highlighting"
```

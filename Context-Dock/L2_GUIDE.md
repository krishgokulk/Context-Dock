# L2 AI System - Complete Guide

## Overview

The L2 AI system is an intelligent assistant similar to VS Code's AI features (like GitHub Copilot) that helps you manage files and automate tasks with user permission and approval workflows.

## Architecture

### Core Components

1. **L2AIFileManager** - Manages file operations
   - Create new files
   - Edit existing files with diff preview
   - Delete files safely
   - Refactor code across multiple files
   - Learn patterns from operations

2. **L2AITaskExecutor** - Automates terminal tasks
   - Analyzes user queries
   - Creates executable task plans
   - Detects and installs required tools
   - Executes commands with approval
   - Suggests reusable extensions

3. **TerminalAIBridge** - Command execution safety
   - Classifies commands by risk level
   - Requests user approval
   - Executes in terminal or background
   - Maintains audit logs
   - Supports multi-step workflows

4. **TerminalCommandClassifier** - Risk assessment
   - Safe commands (auto-execute)
   - Low/medium risk (requires approval)
   - High risk (warning + approval)
   - Critical risk (blocked with alternatives)

## Workflow Examples

### Example 1: File Editing

```
User: "Add error handling to all network calls"
Files: [NetworkManager.swift, APIClient.swift]

Flow:
1. L2AIFileManager analyzes intent → Edit operation
2. AI generates proposed changes with reasoning
3. FileChangesApprovalView shows diff preview
4. User reviews, approves specific changes
5. System applies approved changes
6. Creates backup before modification
7. Learns pattern for future use
```

### Example 2: Task Execution

```
User: "Compress all images in this folder"
Files: [image1.jpg, image2.png, ...]

Flow:
1. L2AITaskExecutor analyzes query
2. Creates todo list:
   - Check if ImageMagick is installed
   - Install via Homebrew if needed
   - Compress each image
3. CommandApprovalView shows each command
4. User approves installation
5. Commands execute with progress tracking
6. Suggests creating reusable extension
```

### Example 3: Learning Patterns

```
After completing 3 similar "Add SwiftUI preview" operations:

L2 learns:
- Pattern name: "Add SwiftUI Preview"
- Trigger: Swift files ending in "View.swift"
- Template: Standard preview code structure
- Success rate: 100%

Next time:
User: "Add preview to MyView.swift"
L2: "I've learned this pattern! Here's what I suggest..."
[Applies learned template with customization]
```

## Safety Features

### Command Classification

**Safe (Auto-execute)**
- Read operations: `ls`, `cat`, `grep`
- System info: `whoami`, `pwd`, `date`
- Git read: `git status`, `git log`

**Medium Risk (Approval Required)**
- File modifications: `mkdir`, `cp`, `mv`
- Package management: `brew install`
- Git write: `git commit`, `git push`

**Blocked (Critical Risk)**
- Recursive deletion: `rm -rf`
- Privilege escalation: `sudo`
- Remote piping: `curl | bash`
- Disk operations: `dd`, `diskutil`

### File Change Safety

1. **Diff Preview** - See exactly what changes before applying
2. **Selective Approval** - Approve/deny each change individually
3. **Automatic Backups** - .backup files created before modification
4. **Trash for Deletions** - Files moved to Trash, not permanently deleted
5. **Reasoning Display** - AI explains why each change is needed

### Audit Trail

- All commands logged to `~/Library/Logs/ILauncher/terminal_audit.log`
- Includes timestamp, risk level, approval status, exit code
- Operation history maintained in memory
- Learning patterns saved to UserDefaults

## UI Components

### L2AIIntegrationView
Main interface with 4 modes:
- **Ask** - Query without changes
- **Edit Files** - AI-assisted file modifications
- **Execute Task** - Terminal automation
- **Learn** - View and manage learned patterns

### FileChangesApprovalView
Split view showing:
- Left: List of proposed changes with checkboxes
- Right: Diff preview with syntax highlighting
- Bottom: Bulk approve/deny actions

### CommandApprovalView
Dialog showing:
- Command details with syntax highlighting
- Risk level badge and explanation
- Purpose/reasoning from AI
- Edit command option
- Remember choice toggle

## Integration Points

### With Existing Systems

```swift
// In your app, connect to AppSettings for AI provider
let aiProvider = appSettings.createAIProvider()

// Process file editing request
await L2AIFileManager.shared.processQuery(
    "Add documentation", 
    files: selectedFiles, 
    aiProvider: aiProvider
)

// Execute terminal task
await L2AITaskExecutor.shared.executeTask(
    query: "Compress images",
    context: fileContext,
    aiProvider: aiProvider
)

// Connect terminal controller for visible execution
TerminalAIBridge.shared.terminalController = myTerminalController
```

### AI Provider Protocol

```swift
protocol AIProviderProtocol {
    func sendQuery(_ query: String) async throws -> String
}
```

Your AI provider should:
1. Accept natural language queries
2. Return structured JSON responses
3. Handle code analysis and generation
4. Support file context understanding

Expected JSON formats:

**For File Editing:**
```json
{
  "newContent": "complete file content",
  "reasoning": "what changed and why",
  "summary": "brief description"
}
```

**For Task Planning:**
```json
{
  "steps": [
    {
      "description": "Install ImageMagick",
      "requiredTool": "imagemagick",
      "command": "brew install imagemagick"
    }
  ]
}
```

## Advanced Features

### Multi-Step Workflows

```swift
let workflow = [
    WorkflowStep(
        command: "git pull",
        description: "Update repository",
        dependsOnPrevious: false
    ),
    WorkflowStep(
        command: "swift build",
        description: "Build project",
        dependsOnPrevious: true
    ),
    WorkflowStep(
        command: "swift test",
        description: "Run tests",
        dependsOnPrevious: true,
        optional: true
    )
]

let result = await TerminalAIBridge.shared.executeWorkflow(
    name: "Update and Test",
    steps: workflow,
    onProgress: { step, description in
        print("Step \(step): \(description)")
    }
)
```

### Learning System

The system learns from:
1. **Successful operations** - Repeated patterns
2. **File types** - Context-specific templates
3. **Project structure** - Swift Package, Xcode, etc.
4. **User preferences** - Approved command patterns

Patterns are triggered by:
- File type matching
- Keyword detection in queries
- Project type identification

### Tool Detection & Installation

```swift
// Detect installed tools
let tools = ["imagemagick", "ffmpeg", "pandoc"]
for tool in tools {
    if let detected = TerminalTool.detect(tool) {
        print("\(tool): \(detected.version)")
        print("Capabilities: \(detected.capabilities)")
    }
}

// Suggest tools for task
let recommended = ToolCapabilities.recommend(
    for: "compress images",
    fileType: "jpg"
)
// Returns: ["imagemagick", "pngquant", "jpegoptim"]
```

## Best Practices

### For Users

1. **Review Before Approving** - Always check diffs and commands
2. **Start Small** - Test with single files before bulk operations
3. **Use Learning** - Let L2 learn your patterns over time
4. **Provide Context** - More specific queries = better results

### For Developers

1. **Validate AI Output** - Always parse JSON responses safely
2. **Handle Errors Gracefully** - AI can fail, have fallbacks
3. **Create Backups** - Before any file modification
4. **Log Everything** - Audit trail is critical for safety
5. **Test Classification** - Ensure dangerous commands are blocked

## Extending the System

### Add New Command Categories

```swift
// In ToolCapabilities.get(for:)
case "my-tool":
    return ["capability1", "capability2"]
```

### Add Custom Risk Patterns

```swift
// In TerminalCommandClassifier
private let customPatterns = [
    ("^my-dangerous-cmd", "Critical", "Explanation", "Alternative")
]
```

### Add Learning Triggers

```swift
// Custom trigger conditions
struct CustomTrigger: Codable {
    let condition: String
    let action: String
}
```

## Troubleshooting

### AI Returns Invalid JSON
- Check prompt format
- Add JSON schema validation
- Implement fallback responses

### Commands Not Executing
- Verify TerminalAIBridge.terminalController is set
- Check command classification isn't blocking
- Review audit logs

### File Changes Not Applying
- Ensure file permissions are correct
- Check for file locks
- Verify backup directory is writable

### Learning Patterns Not Triggering
- Review trigger context matches
- Check keyword extraction
- Verify pattern confidence threshold

## Security Considerations

1. **Never Auto-Execute High Risk Commands**
2. **Always Show Full Command Before Execution**
3. **Maintain Comprehensive Audit Logs**
4. **Use File System Permissions Properly**
5. **Validate All AI-Generated Code**
6. **Don't Store Sensitive Data in Patterns**
7. **Implement Rate Limiting for AI Calls**
8. **Sanitize File Paths and Command Arguments**

## Future Enhancements

- [ ] Multi-file refactoring with dependency analysis
- [ ] Code review and suggestion system
- [ ] Integration with version control for better diffs
- [ ] Natural language debugging assistance
- [ ] Project-wide search and replace
- [ ] Automated test generation
- [ ] Performance profiling suggestions
- [ ] Documentation generation from code
- [ ] CI/CD workflow automation
- [ ] Cross-platform compatibility checks

## Comparison to VS Code AI

| Feature | VS Code AI | L2 AI System |
|---------|-----------|--------------|
| File Editing | ✅ Inline | ✅ Diff Preview |
| Multi-File Changes | ✅ | ✅ |
| Terminal Automation | ❌ | ✅ |
| Tool Installation | ❌ | ✅ |
| Learning Patterns | Limited | ✅ Advanced |
| Risk Classification | ❌ | ✅ Comprehensive |
| Command Approval | ❌ | ✅ Required |
| Audit Logging | ❌ | ✅ Complete |
| macOS Integration | Partial | ✅ Native |

## License & Credits

This system demonstrates AI-assisted development patterns inspired by:
- GitHub Copilot's code suggestions
- VS Code's file diff interface
- Unix philosophy of composable tools
- Apple's Human Interface Guidelines for safety

---

**Version:** 1.0.0  
**Last Updated:** January 14, 2026  
**Maintainer:** Your Name

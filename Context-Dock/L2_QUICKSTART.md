# L2 AI System - Quick Start

## What You Have

A complete L2 AI system similar to VS Code's AI features, with:

✅ **File Management** - AI-assisted editing with diff preview  
✅ **Task Automation** - Terminal command execution with safety  
✅ **Learning System** - Automatically learns patterns from usage  
✅ **Safety Features** - Command classification and approval workflows  
✅ **Audit Logging** - Complete history of all operations  

## Files Created

### Core System
1. **L2AIFileManager.swift** - File operations (create, edit, delete, refactor)
2. **L2AITaskExecutor.swift** - Task automation and tool management
3. **TerminalAIBridge.swift** - Command execution safety layer
4. **TerminalCommandClassifier.swift** - Risk assessment system

### UI Components
5. **FileChangesApprovalView.swift** - Diff preview and approval UI
6. **CommandApprovalView.swift** - Command approval dialog
7. **L2AIIntegrationView.swift** - Main L2 interface
8. **L2AIIntegrationExample.swift** - Complete app integration example

### Documentation
9. **L2_GUIDE.md** - Comprehensive guide
10. **L2_QUICKSTART.md** - This file

## How It Works

```
User Query → AI Analysis → Generate Changes → User Approval → Execute → Learn
```

### Example: File Editing

```swift
// User selects files and types query
let files = [URL(fileURLWithPath: "MyView.swift")]
let query = "Add error handling to network calls"

// Process with L2
await L2AIFileManager.shared.processQuery(
    query, 
    files: files, 
    aiProvider: aiProvider
)

// UI shows FileChangesApprovalView with:
// - Diff preview
// - AI reasoning
// - Individual approval checkboxes

// User approves → Changes applied with backups
```

### Example: Task Execution

```swift
// User types query
let query = "Compress all images"

// Create file context
let context = FileContext(
    selectedFiles: imageFiles,
    fileTypes: ["jpg", "png"],
    totalSize: 1024000
)

// Execute task
await L2AITaskExecutor.shared.executeTask(
    query: query,
    context: context,
    aiProvider: aiProvider
)

// System:
// 1. Creates todo list
// 2. Checks for required tools (ImageMagick)
// 3. Offers to install via Homebrew if needed
// 4. Shows command approval dialog
// 5. Executes each step
// 6. Learns pattern for future use
```

## Integration Steps

### 1. Add to Your App

```swift
import SwiftUI

@main
struct YourApp: App {
    var body: some Scene {
        // Add L2 window
        Window("L2 AI Assistant", id: "l2-ai") {
            L2AIIntegrationView()
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}
```

### 2. Connect AI Provider

```swift
// Implement AIProviderProtocol
extension YourAIProvider: AIProviderProtocol {
    func sendQuery(_ query: String) async throws -> String {
        // Your AI API call here
        // Return JSON response
    }
}
```

### 3. Hook Up Terminal (Optional)

```swift
// If you have a terminal view
TerminalAIBridge.shared.terminalController = yourTerminalController
```

## Key Features

### Safety First 🛡️

- **Risk Classification** - Every command categorized
- **Approval Required** - Medium+ risk needs user OK
- **Blocked Commands** - Critical operations prevented
- **Audit Trail** - Everything logged

### Smart Learning 🧠

- **Pattern Recognition** - Detects repeated operations
- **Context Awareness** - File types, project structure
- **Template Creation** - Reusable patterns
- **Success Tracking** - Learns what works

### User Experience ✨

- **Diff Preview** - See exactly what changes
- **Reasoning Display** - AI explains decisions
- **Selective Approval** - Choose what to apply
- **Progress Tracking** - Visual feedback
- **Undo Safety** - Backups and Trash

## Command Classification Examples

```swift
// Safe (auto-executes)
"ls -la"
"git status"
"cat file.txt"

// Medium Risk (approval required)
"brew install imagemagick"
"git commit -m 'message'"
"mkdir new_folder"

// High Risk (warning + approval)
"rm file.txt"
"git reset HEAD~1"

// Blocked (with alternatives)
"rm -rf /" → Blocked, use Finder instead
"sudo command" → Blocked, run in Terminal.app
"curl url | bash" → Blocked, review script first
```

## Testing the System

### Test 1: File Creation

```swift
// Query: "Create a SwiftUI view called WelcomeView"
// Expected: Generates WelcomeView.swift with basic structure
// Shows: FileChangesApprovalView with preview
// Result: File created after approval
```

### Test 2: File Editing

```swift
// Query: "Add documentation comments to all functions"
// Files: [MyClass.swift]
// Expected: AI adds doc comments
// Shows: Diff with +/- lines
// Result: Applied changes, .backup created
```

### Test 3: Task Execution

```swift
// Query: "Optimize all PNG images"
// Files: [image1.png, image2.png]
// Expected:
//   1. Check for pngquant/optipng
//   2. Offer installation if missing
//   3. Show commands for approval
//   4. Execute compression
//   5. Suggest creating "Optimize Images" extension
```

## Common Use Cases

### 1. Code Refactoring
```
Query: "Convert this class to use async/await"
Result: AI rewrites callbacks to async patterns
```

### 2. Documentation
```
Query: "Add missing documentation"
Result: AI generates doc comments
```

### 3. Error Handling
```
Query: "Add try-catch blocks to all file operations"
Result: AI wraps code in error handling
```

### 4. File Processing
```
Query: "Convert all HEIC images to JPG"
Result: Installs sips/imagemagick, converts files
```

### 5. Project Setup
```
Query: "Set up a new Swift package with testing"
Result: Creates Package.swift, Tests folder, etc.
```

## Keyboard Shortcuts

- `⌘⇧L` - Open L2 AI Assistant
- `⌘↩` - Submit query
- `⌘A` then `Space` - Approve all changes
- `⌘E` - Edit selected change
- `⎋` - Cancel/close

## Tips & Tricks

### Be Specific
❌ "Fix this"  
✅ "Add null checks to prevent crashes"

### Provide Context
❌ "Update files"  
✅ "Update these 3 network managers to use URLSession"

### Review Changes
✅ Always check diffs before approving  
✅ Test with one file before bulk operations

### Let It Learn
✅ Don't skip suggested patterns  
✅ Give feedback on results  
✅ Reuse learned templates

## Troubleshooting

### AI Provider Not Working
- Check your API key/settings
- Verify internet connection
- Look at console for errors

### Commands Not Executing
- Verify permissions
- Check terminal connection
- Review audit log

### Changes Not Applying
- Check file permissions
- Ensure files aren't locked
- Review error messages

## Next Steps

1. ✅ Integrate into your app
2. ✅ Configure AI provider
3. ✅ Test with simple operations
4. ✅ Try file editing workflows
5. ✅ Experiment with task automation
6. ✅ Review learned patterns
7. ✅ Export and share patterns
8. ✅ Customize risk classifications

## Resources

- **Full Guide**: See L2_GUIDE.md
- **Code Examples**: See L2AIIntegrationExample.swift
- **API Reference**: See inline documentation
- **Audit Log**: `~/Library/Logs/ILauncher/terminal_audit.log`

## Support

For issues or questions:
1. Check L2_GUIDE.md
2. Review error messages
3. Check audit log
4. Debug with breakpoints

---

**Version:** 1.0.0  
**Platform:** macOS 13.0+  
**Language:** Swift 5.9+  
**Architecture:** Modern async/await based

Enjoy your AI-powered development experience! 🚀

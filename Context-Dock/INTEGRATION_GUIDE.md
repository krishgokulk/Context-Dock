# Automation Studio Integration Guide

## 🚀 Quick Start

Your app now has a **unified Automation section** in settings that consolidates all extension types into one professional interface!

## 📦 What's Included

### New Files Created

1. **SettingsView.swift**
   - Main settings interface with TabView
   - Automation tab with 6 categories
   - All other settings tabs (General, Appearance, etc.)

2. **AutomationMigrationHelper.swift**
   - Automatic migration from old structure
   - Backup/restore functionality
   - Migration welcome screen

3. **AUTOMATION_ARCHITECTURE.md**
   - Complete architecture documentation
   - Extension format specifications
   - Best practices guide

## 🔧 Integration Steps

### Step 1: Add Files to Xcode

1. Open your Xcode project
2. Drag these files into your project:
   - `SettingsView.swift`
   - `AutomationMigrationHelper.swift`
3. Ensure they're added to your target

### Step 2: Update ILauncherApp.swift

The Settings scene already points to `SettingsView()`, so it should work immediately:

```swift
Settings {
    SettingsView()  // ✅ This now loads the new unified interface
}
```

### Step 3: Run Migration (Optional)

Add migration check on app launch in `AppDelegate.applicationDidFinishLaunching`:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // ... existing code ...
    
    // Run migration if needed
    Task {
        do {
            try await AutomationMigrationHelper.shared.performAutomaticMigration()
        } catch {
            print("⚠️ Migration failed: \(error)")
        }
    }
}
```

### Step 4: Test the Interface

1. Build and run your app
2. Press `Cmd + ,` to open Settings
3. Click the **Automation** tab
4. You should see 6 categories:
   - ⚡ Quick Actions
   - 📄 Context Actions
   - 🧠 AI Tools
   - 💻 Terminal Packages
   - 🌐 Browser Extensions
   - 🔀 Workflows

## 🎨 UI Overview

### Main Layout

```
┌────────────────────────────────────────────────────────────┐
│  🎨 Automation Studio              🔍 [Search]    [+ New]  │
├──────────────┬─────────────────────────────────────────────┤
│              │                                             │
│ ⚡ Quick(5)  │  Panel Header                               │
│ 📄 Context(3)│  ┌──────────────────────────────────────┐  │
│ 🧠 AI Tools  │  │ Extension List                       │  │
│ 💻 Terminal  │  │ • Action 1                           │  │
│ 🌐 Browser   │  │ • Action 2                           │  │
│ 🔀 Workflows │  └──────────────────────────────────────┘  │
│              │                                             │
│──────────────│                                             │
│ Total: 23    │  [Detail Panel]                             │
│ Active: 18   │                                             │
└──────────────┴─────────────────────────────────────────────┘
```

### Features

✅ **Unified Categories** - All extension types in one place  
✅ **Smart Search** - Search across all extensions  
✅ **Color-Coded** - Each category has distinct color  
✅ **Live Stats** - See total and active extension counts  
✅ **Quick Actions** - Add new extensions with one click  
✅ **Professional Design** - Modern, polished interface  

## 📝 Creating Extensions

### Via UI

1. Click **Automation** tab
2. Select a category (e.g., Quick Actions)
3. Click **+ New** button
4. Fill in the form:
   - Name
   - Description
   - Icon (SF Symbol picker)
   - Layer selection
   - Script type
   - Triggers
5. Write or paste your script
6. Click **Add Action**

### Via Import

1. Drag a script file (.sh, .py, .js, etc.) onto the extension list
2. Select target layer
3. Metadata is auto-extracted from comments
4. Script is made executable automatically

### Script Template

```bash
#!/bin/bash
# Name: My Action
# Description: What it does
# Icon: star.fill
# Keywords: trigger, words
# Pattern: ^myaction\s+.+
# Author: Your Name
# Version: 1.0

# Your script here
echo "Hello from ILauncher!"
```

## 🔄 Migration

### Automatic Migration

The migration happens automatically on first launch after integration:

```
🔄 Starting automatic migration...
   ✓ Found 5 Quick Actions
   ✓ Found 3 Context Actions
   ✓ Found 7 AI Tools
   ✓ Found 12 Terminal Packages
   ✓ Verified 27 total extensions
✅ Migration completed successfully
```

### Backup & Restore

Export backup before making changes:

```swift
let backupURL = try await AutomationMigrationHelper.shared.exportExtensionsBackup()
print("Backup saved to: \(backupURL.path)")
```

Restore from backup:

```swift
try await AutomationMigrationHelper.shared.importExtensionsBackup(from: backupURL)
```

## 🎯 Extension Categories

### 1. Quick Actions (L1)
**Trigger:** Keywords in search  
**Examples:** weather, calc, currency  
**Use Case:** Instant utilities

### 2. Context Actions (L2)
**Trigger:** File/app/text selection  
**Examples:** compress, merge pdf, format code  
**Use Case:** Smart contextual operations

### 3. AI Tools
**Trigger:** AI assistant calls  
**Examples:** summarize, extract data, analyze  
**Use Case:** AI-powered automation

### 4. Terminal Packages
**Trigger:** CLI commands  
**Examples:** git, ffmpeg, imagemagick  
**Use Case:** System binaries

### 5. Browser Extensions (L3)
**Trigger:** URLs, web context  
**Examples:** save to pocket, screenshot page  
**Use Case:** Web automation

### 6. Workflows
**Trigger:** Custom chains  
**Examples:** compress → upload → share  
**Use Case:** Multi-step automation  
**Status:** Coming soon

## 🛠 Customization

### Change Category Colors

Edit in `SettingsView.swift`:

```swift
var color: Color {
    switch self {
    case .quickActions: return .blue     // Change to your color
    case .contextActions: return .purple
    // ...
    }
}
```

### Add New Category

1. Add case to `AutomationCategory` enum
2. Add icon and color
3. Create panel view
4. Add to `automationContent` switch

### Modify Panel Layout

Each panel is a separate view:
- `QuickActionsPanel`
- `ContextActionsPanel`
- `AIToolsPanel`
- etc.

Customize by editing the panel views.

## 📊 Statistics & Analytics

Get migration stats:

```swift
let stats = AutomationMigrationHelper.shared.getMigrationStats()
print(stats.summary)
```

Output:
```
Automation Studio Statistics

Total Extensions: 27

By Category:
• Quick Actions: 5
• Context Actions: 3
• AI Tools: 7
• Terminal Packages: 12
• Browser Extensions: 0
• Workflows: 0

Migration Date: Apr 4, 2026
```

## 🐛 Troubleshooting

### Extensions Not Showing

1. Check layer assignment:
   ```swift
   let exts = LayeredExtensionManager.shared.extensions(for: .l2_context)
   print("L2 Extensions: \(exts.count)")
   ```

2. Verify extension is enabled:
   ```swift
   print("Enabled: \(extension.enabled)")
   ```

3. Check triggers are configured:
   ```swift
   print("Triggers: \(extension.triggers)")
   ```

### Migration Failed

1. Check console for error messages
2. Verify extension files exist:
   ```bash
   ls ~/Desktop/ILauncher/StarterExtensions/
   ls ~/Desktop/ILauncher/AIExtensions/
   ```

3. Run manual migration:
   ```swift
   try await AutomationMigrationHelper.shared.performAutomaticMigration()
   ```

### Settings Window Too Small

The window size is set in ILauncherApp.swift:

```swift
Settings {
    SettingsView()
}
.defaultSize(width: 920, height: 680)  // Adjust as needed
```

## 🎓 Best Practices

### Extension Naming

✅ **Good:** "Compress Images", "Merge PDFs", "Weather Lookup"  
❌ **Bad:** "img_compress", "merge", "weather"

### Icon Selection

Use descriptive SF Symbols:
- Images: `photo.fill`, `camera.fill`
- Files: `doc.text.fill`, `folder.fill`
- Network: `globe`, `wifi`
- Tools: `hammer`, `wrench`, `gear`

### Script Performance

- Keep execution under 5 seconds
- Use progress indicators for long operations
- Handle errors gracefully
- Clean up temporary files

### Trigger Design

Be specific to avoid conflicts:
```swift
// ✅ Good - specific pattern
"^compress\\s+images"

// ❌ Bad - too generic
"compress"
```

## 🔮 Future Enhancements

Coming in future versions:

- 🔀 **Workflow Builder** - Visual chain editor
- 🏪 **Extension Marketplace** - Community extensions
- 📈 **Analytics Dashboard** - Usage insights
- 🔄 **Auto-Updates** - Keep extensions current
- 🌍 **Sharing** - Share with other users

## 📚 Documentation

- **Architecture:** See `AUTOMATION_ARCHITECTURE.md`
- **API Reference:** Inline code documentation
- **Examples:** Check `L2ExampleExtension.all`

## 💡 Tips

1. **Use the Search** - Filter extensions quickly
2. **Enable/Disable** - Toggle extensions without deleting
3. **Check Stats** - Monitor which extensions you use most
4. **Backup Regularly** - Export before major changes
5. **Start Simple** - Create basic extensions first

## 🤝 Contributing

To add new features:

1. Fork the project
2. Create feature branch
3. Add your enhancement
4. Test thoroughly
5. Submit pull request

## 📄 License

Same as ILauncher main project.

---

## ✨ You're All Set!

Your ILauncher now has a professional, unified Automation Studio! 

**Next Steps:**
1. Build and run the app
2. Open Settings (Cmd+,)
3. Click **Automation** tab
4. Explore your extensions
5. Create something awesome!

For questions or issues, check the troubleshooting section or review the architecture docs.

**Happy Automating! 🚀**

# ILauncher Automation Architecture

## Overview

The **Automation Studio** is ILauncher's unified extension management system. It consolidates all extension types (Quick Actions, Context Actions, AI Tools, Terminal Packages, Browser Extensions, and Workflows) into a single, professional interface.

## Architecture

### Unified Settings Tab

**Before:** Extensions were scattered across multiple settings panels:
- Quick Actions (in Advanced)
- Context Dock (separate section)
- Extensions (in Advanced)
- Terminal Packages (separate)

**After:** All automation is centralized in the **Automation** tab:
```
Settings
├── General
├── **Automation** ← NEW: Unified Extension Hub
│   ├── Quick Actions (L1)
│   ├── Context Actions (L2)
│   ├── AI Tools (L2 Terminal)
│   ├── Terminal Packages
│   ├── Browser Extensions (L3)
│   └── Workflows (Cross-Layer)
├── Appearance
├── Hotkeys
├── Privacy
└── About
```

---

## Extension Categories

### 1. **Quick Actions** (L1 - Search Layer)
- **Icon:** ⚡ (bolt.circle.fill)
- **Color:** Blue
- **Trigger:** Keywords typed in search
- **Use Case:** Instant actions like "weather", "calc 2+2", "currency 100 USD to EUR"
- **Examples:**
  - Calculator
  - Weather lookup
  - Currency converter
  - Unit converter
  - Dictionary

### 2. **Context Actions** (L2 - Context Layer)
- **Icon:** 📄 (doc.on.doc.fill)
- **Color:** Purple
- **Trigger:** File selection, app focus, text selection
- **Use Case:** Smart actions based on what you're working with
- **Examples:**
  - Compress selected images
  - Merge PDFs
  - Send files via email
  - Convert video formats
  - Format code files

### 3. **AI Tools** (L2 Terminal)
- **Icon:** 🧠 (brain.head.profile)
- **Color:** Pink
- **Trigger:** Called by L2 AI assistant
- **Use Case:** AI can automatically invoke these tools when needed
- **Examples:**
  - File compression
  - Image resizing
  - Text summarization
  - Code formatting
  - Data extraction

### 4. **Terminal Packages**
- **Icon:** 💻 (terminal.fill)
- **Color:** Green
- **Trigger:** Manual or AI-invoked CLI commands
- **Use Case:** System binaries and CLI tools
- **Examples:**
  - git
  - ffmpeg
  - imagemagick
  - pandoc
  - jq

### 5. **Browser Extensions** (L3)
- **Icon:** 🌐 (safari.fill)
- **Color:** Orange
- **Trigger:** Web URLs, browser context
- **Use Case:** Web automation and browser integrations
- **Examples:**
  - Save to Pocket
  - Share on Twitter
  - Archive webpage
  - Extract article text
  - Screenshot full page

### 6. **Workflows** (Cross-Layer)
- **Icon:** 🔀 (arrow.triangle.branch)
- **Color:** Cyan
- **Trigger:** Custom conditions and chains
- **Use Case:** Multi-step automation
- **Status:** Coming Soon
- **Examples:**
  - Compress → Upload → Share Link
  - Download → Convert → Save to Drive
  - Screenshot → Annotate → Send Email

---

## UI Components

### 1. Automation Header
```swift
┌─────────────────────────────────────────────────────────┐
│ 🎨 Automation Studio                    🔍 [Search...]  │
│    Extend ILauncher with powerful actions    [+ New ▼]  │
└─────────────────────────────────────────────────────────┘
```

**Features:**
- Gradient branding icon (blue → purple → pink)
- Contextual search across all extensions
- Quick-add menu for creating new extensions
- Reload all button

### 2. Category Sidebar
```swift
┌──────────────────────────┐
│ ⚡ Quick Actions      (5) │
│ 📄 Context Actions   (3) │
│ 🧠 AI Tools          (7) │
│ 💻 Terminal Packages (12)│
│ 🌐 Browser Extensions (2)│
│ 🔀 Workflows         (0) │
├──────────────────────────┤
│ 📊 Total Extensions: 29  │
│ ⚡ Active Now: 24        │
└──────────────────────────┘
```

**Features:**
- Color-coded categories
- Live extension counts
- Visual selection state
- Summary statistics

### 3. Extension List
```swift
┌────────────────────────────────────┐
│ ⚡ Compress Images                 │
│    Reduce image file sizes         │
│    "compress"                      │
├────────────────────────────────────┤
│ 📄 Merge PDFs                      │
│    Combine multiple PDFs           │
│    pdf, pdf                        │
└────────────────────────────────────┘
```

**Features:**
- Extension icon with color
- Name, description, trigger preview
- Enable/disable toggle
- Built-in badge for system extensions
- Usage statistics

### 4. Detail Panel
```swift
┌──────────────────────────┐
│ ⚡ Compress Images        │
│    v1.0 · me        ON   │
├──────────────────────────┤
│ Reduce image file sizes  │
│                          │
│ TRIGGERS                 │
│ • Keywords: compress     │
│ • File types: jpg, png   │
│                          │
│ DETAILS                  │
│ Layer: Quick Actions     │
│ Category: Image          │
├──────────────────────────┤
│ [Edit]          [Delete] │
└──────────────────────────┘
```

**Features:**
- Quick enable/disable
- Detailed trigger information
- Metadata display
- Edit/delete actions

---

## Implementation Guide

### 1. Create New Extension

```swift
// User clicks "New" → QuickActionEditorView opens
QuickActionEditorView(
    extensionManager: extensionManager,
    existing: nil,
    defaultLayer: .l2_context,  // Pre-selected layer
    onSave: { /* reload */ }
)
```

**Editor Features:**
- Icon picker with SF Symbols
- Name and description fields
- Layer selector (L1/L2/L3/Cross)
- Script type selector (Bash/Python/Swift/JS)
- Trigger configuration:
  - Keywords
  - File types
  - App context
- Live script editor with templates
- Syntax highlighting
- "Paste from AI" button for Claude/GPT code

### 2. Import Extension

```swift
// Drag & drop or file picker
ImportExtensionDialog(
    fileURL: droppedFile,
    selectedLayer: .l2_context,
    onImport: { layer in
        // Auto-parse metadata from comments
        // Make executable
        // Register in extensions.json
    }
)
```

**Auto-Configuration:**
- Extract name, description, icon from script comments
- Detect script type from shebang
- Generate default patterns
- Set permissions (chmod +x)
- Register in appropriate layer

### 3. AI Tool Integration

```swift
// AI Tools panel uses L2ExtensionManager
@StateObject private var l2Manager = L2ExtensionManager.shared

// Show examples gallery
ForEach(L2ExampleExtension.all) { example in
    L2ExampleCard(example: example) {
        // Install with one tap
    }
}

// Custom tools
L2ExtensionEditorSheet(onSave: { /* reload */ })
```

**L2 Tool Format:**
```json
{
  "name": "Compress Images",
  "description": "Reduce image file sizes",
  "parameters": [
    {
      "name": "files",
      "type": "array",
      "description": "Image files to compress"
    },
    {
      "name": "quality",
      "type": "integer",
      "description": "Quality level (1-100)"
    }
  ],
  "scriptPath": "compress_images.sh"
}
```

---

## Extension Metadata Format

### Script Header Comments

Extensions can include metadata in script comments:

```bash
#!/bin/bash
# Name: Compress Images
# Description: Reduce image file sizes while preserving quality
# Icon: photo.fill
# Keywords: compress, optimize, reduce, shrink
# Pattern: ^compress\s+.+
# Pattern: ^optimize\s+images
# Author: Your Name
# Version: 1.0
```

**Supported Fields:**
- `Name:` Display name
- `Description:` What the extension does
- `Icon:` SF Symbol name
- `Keywords:` Comma-separated trigger words
- `Pattern:` Regex patterns for matching
- `Author:` Creator name
- `Version:` Semantic version

### JSON Configuration

```json
{
  "id": "compress-images",
  "name": "Compress Images",
  "description": "Reduce image file sizes",
  "script": "compress_images.sh",
  "icon": "photo.fill",
  "keywords": ["compress", "optimize"],
  "patterns": ["^compress\\s+.+"],
  "layer": "l2_context",
  "triggers": [
    {
      "type": "fileType",
      "values": ["jpg", "png", "jpeg"]
    }
  ],
  "enabled": true,
  "priority": 20
}
```

---

## Best Practices

### Extension Organization

1. **Use Clear Names:** "Compress Images" not "img_compress"
2. **Descriptive Icons:** Match icon to function (photo.fill for images)
3. **Specific Triggers:** Use precise keywords to avoid conflicts
4. **Layer Selection:**
   - L1 for keyword-based searches
   - L2 for file/context operations
   - L3 for web actions
   - Cross-Layer for multi-step workflows

### Performance

1. **Fast Execution:** Keep scripts under 5 seconds for responsiveness
2. **Error Handling:** Always include error messages
3. **Progress Feedback:** Use stdout for progress updates
4. **Resource Cleanup:** Close files, remove temp data

### User Experience

1. **Helpful Descriptions:** Explain what the action does clearly
2. **Example Usage:** Include in description ("Type 'weather london'")
3. **Sensible Defaults:** Pre-fill common parameters
4. **Confirmations:** Ask before destructive operations

---

## Migration Guide

### Moving from Old Structure to Automation Studio

**Step 1: Quick Actions**
```
Old: Settings → Advanced → Quick Actions
New: Settings → Automation → Quick Actions
```

**Step 2: Context Actions**
```
Old: Settings → Context Dock → Actions
New: Settings → Automation → Context Actions
```

**Step 3: AI Tools**
```
Old: Settings → Advanced → L2 AI Tools
New: Settings → Automation → AI Tools
```

**Step 4: Terminal**
```
Old: Settings → Terminal Packages
New: Settings → Automation → Terminal Packages
```

### Code Changes

Replace scattered settings views:

```swift
// OLD
TabView {
    GeneralSettings()
    QuickActionsSettings()
    ContextDockSettings()
    ExtensionsSettings()
    AdvancedSettings() {
        L2AIToolsSettings()
    }
}

// NEW
TabView {
    GeneralSettings()
    AutomationSettings()  // ← Unified
    AppearanceSettings()
}
```

---

## Future Enhancements

### Workflow Builder (Coming Soon)

Visual workflow editor for chaining actions:

```
[Select Files] → [Compress] → [Upload to Drive] → [Copy Link]
     ↓
[If Error] → [Show Notification]
```

**Features:**
- Drag-and-drop action nodes
- Conditional branches
- Variable passing between steps
- Scheduled execution
- Webhook triggers

### Extension Marketplace

Community extensions:

```
┌─────────────────────────────┐
│ 🌟 Featured Extensions      │
├─────────────────────────────┤
│ ⭐ PDF Swiss Army Knife     │
│    Merge, split, compress   │
│    ⬇️ 1.2k  ⭐ 4.8          │
└─────────────────────────────┘
```

**Features:**
- Browse community extensions
- One-click installation
- Ratings and reviews
- Auto-updates
- Developer profiles

### Analytics Dashboard

Extension usage insights:

```
┌──────────────────────────┐
│ 📊 Most Used (30 days)   │
├──────────────────────────┤
│ 1. Weather        (342x) │
│ 2. Calculator     (289x) │
│ 3. Compress       (156x) │
└──────────────────────────┘
```

---

## API Reference

### ExtensionManager

```swift
class LayeredExtensionManager: ObservableObject {
    @Published var allExtensions: [ILExtension]
    
    func loadExtensions() async
    func addExtension(_ extension: ILExtension)
    func updateExtension(_ extension: ILExtension)
    func deleteExtension(_ extension: ILExtension)
    func extensions(for layer: ExtensionLayer) -> [ILExtension]
}
```

### L2ExtensionManager

```swift
class L2ExtensionManager: ObservableObject {
    @Published var extensions: [L2Extension]
    
    func loadExtensions() async
    func executeExtension(_ id: String, parameters: [String: Any]) async -> Result<String, Error>
}
```

### TerminalPackageManager

```swift
class TerminalPackageManager: ObservableObject {
    @Published var packages: [TerminalPackage]
    
    func scanBinaries() async
    func executeCommand(_ command: String) async -> String
}
```

---

## Support

For questions or issues with the Automation Studio:

1. Check the **About** tab for system info
2. Review extension logs in Console.app
3. Test extensions individually before chaining
4. Report bugs with extension JSON attached

---

## Changelog

### v2.0 - Automation Studio Launch
- ✨ Unified extension management interface
- 🎨 Professional category-based organization
- 🔧 Enhanced extension editor with templates
- 📦 Import/export functionality
- 📊 Extension analytics and statistics
- 🧠 AI Tools integration
- 💻 Terminal package management
- 🌐 Browser extension support

### Future Roadmap
- 🔀 Workflow builder
- 🏪 Extension marketplace
- 📈 Advanced analytics
- 🔄 Auto-updates
- 🌍 Extension sharing

---

**Built with ❤️ for ILauncher**

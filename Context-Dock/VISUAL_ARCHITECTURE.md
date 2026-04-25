# Automation Studio - Visual Architecture

## 🎨 UI Layout

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                          ILauncher Settings                                  │
├──────────────────────────────────────────────────────────────────────────────┤
│  [General] [🎨 Automation] [Appearance] [Hotkeys] [Privacy] [About]         │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  🎨 Automation Studio              🔍 [Search extensions]  [+ New]  │    │
│  │     Extend ILauncher with powerful actions                          │    │
│  ├──────────────┬──────────────────────────────────────────────────────┤    │
│  │              │                                                       │    │
│  │  CATEGORIES  │  ⚡ Quick Actions                                     │    │
│  │              │  Keyword-triggered actions in search results         │    │
│  │ ⚡ Quick (5)  │  ┌─────────────────────────────────────────────┐    │    │
│  │ 📄 Context(3)│  │ ⚡ Weather Lookup              [Details >]  │    │    │
│  │ 🧠 AI (7)    │  │    Get current weather forecast             │    │    │
│  │ 💻 Term (12) │  │    Keywords: weather, forecast              │    │    │
│  │ 🌐 Browser(2)│  ├─────────────────────────────────────────────┤    │    │
│  │ 🔀 Work (0)  │  │ ⚡ Calculator                  [Details >]  │    │    │
│  │              │  │    Perform calculations                     │    │    │
│  │──────────────│  │    Keywords: calc, math                     │    │    │
│  │              │  ├─────────────────────────────────────────────┤    │    │
│  │  STATISTICS  │  │ ⚡ Currency Converter          [Details >]  │    │    │
│  │              │  │    Convert between currencies               │    │    │
│  │ Total: 29    │  │    Keywords: currency, convert              │    │    │
│  │ Active: 24   │  └─────────────────────────────────────────────┘    │    │
│  │              │                                                       │    │
│  └──────────────┴───────────────────────────────────────────────────────┘    │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 📱 Panel Structure

### Quick Actions Panel
```
┌────────────────────────────────────────────────────────────────┐
│ ⚡ Quick Actions                              [+ New Action]   │
│ Keyword-triggered actions that appear in search results        │
├────────────────┬───────────────────────────────────────────────┤
│                │                                               │
│  Extension     │  Extension Detail                             │
│  List          │  ┌──────────────────────────────────┐         │
│                │  │ ⚡ Weather Lookup         [ON]   │         │
│  ⚡ Weather     │  │    v1.0 · Built-in              │         │
│  ⚡ Calculator  │  ├──────────────────────────────────┤         │
│  ⚡ Currency    │  │ Get weather for any city         │         │
│  ⚡ Unit Conv   │  │                                  │         │
│  ⚡ Dictionary  │  │ TRIGGERS                         │         │
│                │  │ • Keywords: weather, forecast    │         │
│                │  │                                  │         │
│                │  │ DETAILS                          │         │
│                │  │ Layer: Quick Actions             │         │
│                │  │ Category: Utility                │         │
│                │  │ Used: 342 times                  │         │
│                │  └──────────────────────────────────┘         │
│                │                                               │
└────────────────┴───────────────────────────────────────────────┘
```

### AI Tools Panel
```
┌────────────────────────────────────────────────────────────────┐
│ 🧠 AI Tools                                   [+ New AI Tool]  │
│ AI-powered tools callable by the L2 terminal assistant         │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  📚 Example Tools Gallery (tap to install)                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│  │ 📷 Image │  │ 📄 PDF   │  │ 📝 Text  │  │ 🎬 Video │      │
│  │ Compress │  │ Merge    │  │ Summary  │  │ Convert  │      │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘      │
│                                                                │
│  💡 How AI Tools Work                                          │
│  When you chat in L2 terminal, the AI can call these tools    │
│  automatically. Say "compress my files" → AI picks the         │
│  right tool → runs it → shows result.                          │
│                                                                │
│  Installed Tools (7)                                           │
│  ┌──────────────────────────────────────────────────────┐     │
│  │ 🧠 Summarize Text                            [ON]    │     │
│  │    Extract key points from long text                 │     │
│  │    Parameters: text, max_length                      │     │
│  ├──────────────────────────────────────────────────────┤     │
│  │ 🧠 Extract Data                              [ON]    │     │
│  │    Pull structured data from unstructured text       │     │
│  │    Parameters: text, schema                          │     │
│  └──────────────────────────────────────────────────────┘     │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### Terminal Packages Panel
```
┌────────────────────────────────────────────────────────────────┐
│ 💻 Terminal Packages                          [Scan System]   │
│ System CLI tools and binaries for advanced automation          │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  Auto-Discovered Packages (12)                                 │
│  ┌──────────────────────────────────────────────────────┐     │
│  │ 💻 git                                       [ON]    │     │
│  │    Version control system                            │     │
│  │    Location: /usr/bin/git                            │     │
│  │    Version: 2.39.0                                   │     │
│  ├──────────────────────────────────────────────────────┤     │
│  │ 💻 ffmpeg                                    [ON]    │     │
│  │    Video/audio processing                            │     │
│  │    Location: /opt/homebrew/bin/ffmpeg                │     │
│  │    Version: 6.0                                      │     │
│  ├──────────────────────────────────────────────────────┤     │
│  │ 💻 imagemagick                               [ON]    │     │
│  │    Image manipulation                                │     │
│  │    Location: /opt/homebrew/bin/convert               │     │
│  └──────────────────────────────────────────────────────┘     │
│                                                                │
│  [Install from Homebrew]  [Add Custom Package]                │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

---

## 🎯 Category Navigation

```
Sidebar
├── ⚡ Quick Actions (5)      ← Blue
│   └── L1 Search Layer
│
├── 📄 Context Actions (3)    ← Purple
│   └── L2 Context Layer
│
├── 🧠 AI Tools (7)            ← Pink
│   └── L2 Terminal
│
├── 💻 Terminal Packages (12)  ← Green
│   └── System Binaries
│
├── 🌐 Browser Extensions (2)  ← Orange
│   └── L3 Browser Layer
│
└── 🔀 Workflows (0)           ← Cyan
    └── Cross-Layer
```

---

## 🔄 Data Flow

### Extension Creation Flow
```
User Action
    │
    ├─> Click "+ New"
    │       │
    │       └─> QuickActionEditorView
    │               │
    │               ├─> Select Layer
    │               ├─> Choose Icon
    │               ├─> Write Script
    │               └─> Configure Triggers
    │                       │
    │                       └─> Save
    │                               │
    ├─────────────────────────────┘
    │
    └─> LayeredExtensionManager
            │
            ├─> Validate Extension
            ├─> Save to Disk
            └─> Reload Extensions
                    │
                    └─> UI Updates
```

### Extension Execution Flow
```
User Types in Search
    │
    └─> L1 Search Layer
            │
            ├─> Match Keywords
            │       │
            │       └─> Quick Actions
            │               │
            │               └─> Execute Script
            │
            └─> Context Detection
                    │
                    └─> L2 Context Layer
                            │
                            └─> Context Actions
                                    │
                                    └─> Execute Script
```

### AI Tool Invocation Flow
```
User Chats with L2
    │
    └─> AI Assistant
            │
            ├─> Parse Intent
            ├─> Match Tool
            │       │
            │       └─> L2ExtensionManager
            │               │
            │               └─> Find Matching Tool
            │
            └─> Execute Tool
                    │
                    ├─> Pass Parameters
                    ├─> Run Script
                    └─> Return Result
                            │
                            └─> Format Response
                                    │
                                    └─> Show to User
```

---

## 🎨 Color System

### Category Colors
```
⚡ Quick Actions     → #007AFF (Blue)
📄 Context Actions   → #AF52DE (Purple)
🧠 AI Tools          → #FF2D55 (Pink)
💻 Terminal Packages → #34C759 (Green)
🌐 Browser           → #FF9500 (Orange)
🔀 Workflows         → #5AC8FA (Cyan)
```

### State Colors
```
Enabled     → Green accent
Disabled    → Gray
Selected    → Blue highlight
Built-in    → Blue badge
Custom      → No badge
Error       → Red
```

---

## 📊 Component Hierarchy

```
SettingsView
├── TabView
    ├── GeneralSettingsView
    ├── AutomationSettingsView ⭐
    │   ├── automationHeader
    │   │   ├── Branding (gradient icon + title)
    │   │   ├── Search field
    │   │   └── Action buttons
    │   │
    │   ├── HSplitView
    │   │   ├── automationSidebar
    │   │   │   ├── CategoryRow × 6
    │   │   │   └── Statistics footer
    │   │   │
    │   │   └── automationContent
    │   │       ├── QuickActionsPanel
    │   │       │   └── LayeredExtensionsPanelView
    │   │       │
    │   │       ├── ContextActionsPanel
    │   │       │   └── LayeredExtensionsPanelView
    │   │       │
    │   │       ├── AIToolsPanel
    │   │       │   ├── Example Gallery
    │   │       │   ├── How It Works
    │   │       │   └── Installed Tools List
    │   │       │
    │   │       ├── TerminalPackagesPanel
    │   │       │   └── TerminalSettingsView
    │   │       │
    │   │       ├── BrowserExtensionsPanel
    │   │       │   └── LayeredExtensionsPanelView
    │   │       │
    │   │       └── WorkflowsPanel
    │   │           └── Coming Soon
    │   │
    │   └── Sheets
    │       ├── QuickActionEditorView
    │       └── L2ExtensionEditorSheet
    │
    ├── AppearanceSettingsView
    ├── HotkeysSettingsView
    ├── PrivacySettingsView
    └── AboutSettingsView
```

---

## 🔧 Key Components

### 1. AutomationSettingsView
**Purpose:** Main container for Automation Studio  
**Features:**
- Category navigation
- Search functionality
- Statistics display
- Panel switching

### 2. CategoryRow
**Purpose:** Sidebar category item  
**Features:**
- Color-coded icon
- Extension count badge
- Selection highlighting
- Tap to switch panel

### 3. PanelHeader
**Purpose:** Panel title bar  
**Features:**
- Category icon and name
- Description text
- Action buttons (+ New, Reload, etc.)

### 4. LayeredExtensionsPanelView
**Purpose:** Reusable panel for extension layers  
**Features:**
- Extension list with search
- Detail view with info
- Edit/delete actions
- Enable/disable toggle

### 5. QuickActionEditorView
**Purpose:** Create/edit extensions  
**Features:**
- Icon picker (SF Symbols)
- Script type selector
- Trigger configuration
- Live script editor
- Template system

---

## 🎯 Extension Types

```
Extension Types
│
├── Quick Actions (L1)
│   ├── Trigger: Keywords
│   ├── Examples: weather, calc
│   └── Panel: QuickActionsPanel
│
├── Context Actions (L2)
│   ├── Trigger: Files/Apps/Text
│   ├── Examples: compress, merge
│   └── Panel: ContextActionsPanel
│
├── AI Tools
│   ├── Trigger: AI calls
│   ├── Examples: summarize, extract
│   └── Panel: AIToolsPanel
│
├── Terminal Packages
│   ├── Trigger: CLI commands
│   ├── Examples: git, ffmpeg
│   └── Panel: TerminalPackagesPanel
│
├── Browser Extensions (L3)
│   ├── Trigger: URLs
│   ├── Examples: save, share
│   └── Panel: BrowserExtensionsPanel
│
└── Workflows
    ├── Trigger: Chains
    ├── Examples: compress→upload
    └── Panel: WorkflowsPanel
```

---

## 🚀 State Management

```
@StateObject Managers
│
├── LayeredExtensionManager
│   ├── @Published allExtensions
│   ├── extensions(for:)
│   ├── addExtension()
│   └── updateExtension()
│
├── L2ExtensionManager
│   ├── @Published extensions
│   ├── loadExtensions()
│   └── executeExtension()
│
└── TerminalPackageManager
    ├── @Published packages
    ├── scanBinaries()
    └── executeCommand()

@State Local State
│
├── selectedCategory
├── searchText
├── selectedExtension
├── showingAddExtension
└── showingImportDialog
```

---

## 📱 Responsive Layout

### Wide Screen (>900px)
```
┌────────────────────────────────────┐
│  [Sidebar] [List] [Detail]         │
│   240px     400px   300px          │
└────────────────────────────────────┘
```

### Medium Screen (700-900px)
```
┌──────────────────────────┐
│  [Sidebar] [List+Detail] │
│   220px      480px       │
└──────────────────────────┘
```

### Narrow Screen (<700px)
```
┌──────────────┐
│ [Categories] │
│ [Extensions] │
│   (stacked)  │
└──────────────┘
```

---

## 🎨 Visual States

### Extension Card States
```
Default
┌──────────────────────┐
│ ⚡ Extension Name    │
│    Description       │
│    trigger           │
└──────────────────────┘

Hovered
┌──────────────────────┐
│ ⚡ Extension Name ✨  │  ← highlight
│    Description       │
│    trigger           │
└──────────────────────┘

Selected
┌══════════════════════┐
║ ⚡ Extension Name    ║  ← blue border
║    Description       ║
║    trigger           ║
└══════════════════════┘

Disabled
┌──────────────────────┐
│ ⚡ Extension Name 🔇 │  ← gray + badge
│    Description       │
│    trigger           │
└──────────────────────┘
```

---

**Built for ILauncher L2 🚀**

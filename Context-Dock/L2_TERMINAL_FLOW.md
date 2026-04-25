# L2 AI-Powered Terminal Layer

## Overview
L2 is an **AI-powered terminal** that understands natural language and auto-generates commands for you. Just ask what you want - L2 figures out the commands, checks if packages are installed, and handles everything.

## ✨ Key Features

### 🤖 Natural Language Command Generation
- **Ask anything**: "show wifi details", "check disk space", "download this video"
- **AI figures out commands**: Generates correct terminal commands automatically
- **Smart execution**: Safe commands run immediately, risky ones ask for approval

### 📦 Smart Package Management  
- **Auto-detection**: Detects if required packages are missing
- **Install prompts**: "Need yt-dlp for this. Install it?"
- **Brew integration**: Browse all installed Homebrew packages
- **GitHub import**: Paste any GitHub repo URL → reads README → configures package

### 🎯 Three Execution Modes

#### 1. Auto-Execute (Safe Commands)
```
User: "show wifi details"
L2: [Executes network commands automatically]
Chat: ✅ WiFi Information Retrieved
      SSID: MyNetwork
      IP: 192.168.1.100
      Signal: -45 dBm
```

#### 2. Approval Required (Medium Risk)
```
User: "install yt-dlp"  
L2: Execute this command?
    
    brew install yt-dlp
    
    Purpose: Install YouTube downloader
    
    [✓ Yes] [✗ Cancel]
```

#### 3. Blocked (Dangerous)
```
User: "delete all files"
L2: ⛔️ Command blocked for safety
    Reason: Recursive deletion is dangerous
```

---

## User Experience

### Flow 1: Basic System Info (Auto-Execute)
**Example:** `"show wifi details"`

1. User types in L2: `"show wifi details"`
2. L2 AI generates commands: `networksetup -getinfo Wi-Fi`, `ifconfig en0`
3. **Executes immediately** (safe commands)
4. Chat shows **formatted results**:
```
✅ WiFi Information

SSID: MyNetwork
IP Address: 192.168.1.100
Router: 192.168.1.1
DNS: 8.8.8.8
Signal: -45 dBm (Excellent)
```
5. Full output in Terminal panel

**More examples:**
- `"check disk space"` → Shows storage breakdown
- `"list running processes"` → Top CPU/memory users
- `"show battery status"` → Battery health info
- `"get ip address"` → Your IP addresses

---

### Flow 2: Package Required (Smart Install)
**Example:** `"download this video"`

1. User types: `"download this video"` (while on YouTube)
2. L2 checks: Is `yt-dlp` configured for video downloads?
3. Not found → Chat shows:
```
To download videos, I need yt-dlp.

[✓ Install yt-dlp] [✗ Cancel]
```
4. User clicks **Install**
5. L2: `brew install yt-dlp` (with approval)
6. After install → configures it automatically
7. Next time: `"download this video"` works immediately!

---

### Flow 3: GitHub Package Import
**Example:** Adding a custom tool

1. User opens **Settings → Terminal → GitHub button**
2. Pastes: `https://github.com/yt-dlp/yt-dlp`
3. L2:
   - Fetches README from GitHub
   - Parses installation method (`brew install yt-dlp`)
   - Extracts usage examples
   - Identifies keywords: "youtube", "video", "download"
4. Shows preview:
```
Package: yt-dlp
Command: yt-dlp
Description: YouTube downloader and more
Keywords: youtube, video, download

[Install with Homebrew]
```
5. Installs and configures → ready to use!

---

### Flow 4: Brew Package Browser
**Example:** Browse installed tools

1. User opens **Settings → Terminal → Brew button**
2. Shows all installed Homebrew packages with:
   - Package name & version
   - Description
   - Homepage link
   - **[Add to L2]** button
3. Click **Add to L2** → package becomes available for natural language

---

## What Appears Where

### In Chat (L2 Messages)
- ✅ **Formatted results** for system info
- 🤔 **Approval prompts** with Yes/Cancel
- 📦 **Package install prompts**
- ⛔️ **Blocked command warnings**
- **NO raw terminal output** (keeps chat clean & readable)

### In Terminal Panel  
- 📟 Live command execution
- 📊 Raw output (stdout + stderr)
- 🕐 Execution time
- ✓ Exit codes
- 📝 Command history

---

## Configuration

### Terminal Settings (Settings → Terminal)

#### 1. Scan System
- Auto-detects installed CLI tools
- Finds: yt-dlp, ffmpeg, brew, git, npm, etc.
- Configures them for L2 use

#### 2. Set Task Defaults
Configure which package handles each task:
- **Video Download** → yt-dlp
- **Package Management** → brew  
- **Image Processing** → imagemagick
- **Version Control** → git
- **File Sync** → rsync

#### 3. GitHub Import
- Paste any GitHub repository URL
- Reads README automatically
- Extracts: command name, description, usage
- Offers to install via Homebrew

#### 4. Brew Manager
- Lists all installed Homebrew packages
- Shows: name, version, description, homepage
- Click **Add to L2** to enable for natural language

---

## Natural Language Examples

### System Information (Auto-Execute)
```
"show wifi details"        → Network info
"check disk space"         → df -h with formatting
"list running processes"   → top command
"show battery status"      → Battery health
"get my ip address"        → ifconfig parsing
"show system info"         → System profiler
"check memory usage"       → vm_stat
"list connected devices"   → System devices
```

### Package Management (With Approval)
```
"update all packages"      → brew upgrade (asks approval)
"install ffmpeg"           → brew install ffmpeg
"remove unused packages"   → brew cleanup (asks approval)
"list installed packages"  → brew list (auto-execute)
"search for node"          → brew search node
```

### File Operations (With Approval)
```
"compress these images"    → Uses imagemagick if configured
"convert pdf to text"      → Uses appropriate tool
"sync this folder"         → rsync with smart options
"backup downloads"         → Creates archive
```

### Media Processing (Smart Package Detection)
```
"download this video"      → yt-dlp (installs if missing)
"download as mp3"          → yt-dlp -x --audio-format mp3
"convert video to gif"     → ffmpeg (prompts if missing)
```

---

## AI Command Generation Examples

### WiFi Details
**User:** `"show wifi details"`

**L2 generates:**
```bash
networksetup -getinfo Wi-Fi
ifconfig en0 | grep inet
airport -I
```

**Chat shows formatted:**
```
✅ WiFi Information

SSID: MyNetwork
IP Address: 192.168.1.100
Subnet: 255.255.255.0
Router: 192.168.1.1
DNS: 8.8.8.8, 8.8.4.4
Signal Strength: -45 dBm (Excellent)
Channel: 149 (5 GHz)
Speed: 1300 Mbps
```

### Disk Space
**User:** `"check disk space"`

**L2 generates:** `df -h`

**Chat shows formatted:**
```
✅ Disk Space

/ (Macintosh HD)
  Used: 234 GB / 500 GB (47%)
  Available: 266 GB
  
/Volumes/Backup
  Used: 890 GB / 2 TB (45%)
  Available: 1.1 TB
```

### Missing Package Detection
**User:** `"download youtube.com/watch?v=..."`

**L2 detects:** No video downloader configured

**Chat shows:**
```
To download videos, I need a downloader.

Recommended: yt-dlp
- YouTube and 1000+ sites
- Audio extraction
- Quality selection

[✓ Install yt-dlp] [✗ Cancel]
```

---

## GitHub Package Import

### How It Works
1. Paste GitHub URL: `https://github.com/owner/repo`
2. L2 fetches `README.md` via GitHub API
3. Parses for:
   - Installation command (`brew install`, `cargo install`, `npm install -g`)
   - Description (first paragraph)
   - Usage examples (code blocks)
   - Keywords (extracted from description)
4. Creates package configuration
5. Offers to install

### Example: Importing `bat`
```
URL: https://github.com/sharkdp/bat

L2 reads README:
- Command: bat
- Install: brew install bat
- Description: "A cat clone with syntax highlighting"
- Keywords: ["cat", "syntax", "highlighting"]
- Examples: 
  - bat file.txt
  - bat --style=numbers file.py

Result:
✅ Package 'bat' configured
   Now you can say: "show file with syntax highlighting"
```

---

## Brew Package Manager Integration

### Features
- **Browse** all installed Homebrew packages
- **Search** by name or description
- **View** version, description, homepage
- **Add to L2** with one click

### Use Cases

#### 1. Enable Existing Tools
Already have `ffmpeg` installed via Homebrew?
1. Open Brew Manager
2. Find "ffmpeg"
3. Click **Add to L2**
4. Now: `"convert video to mp4"` works!

#### 2. Discover Installed Tools
See what you have installed and enable for L2 use

#### 3. Quick Configuration
Bulk-add tools you use frequently

---

## Benefits

✅ **Natural Language** - No need to remember commands  
✅ **Smart Detection** - Auto-detects missing packages  
✅ **Safe Execution** - Approvals for risky commands  
✅ **Clean Chat** - Formatted results, not raw output  
✅ **GitHub Import** - Any CLI tool from GitHub  
✅ **Brew Integration** - Manage Homebrew packages  
✅ **Context-Aware** - Uses current URL, files, etc.  
✅ **Learning** - Remembers your preferences  

---

## Technical Details

### Command Generation Flow
1. User query → **Intent Parser**
2. Check configured packages → **Package Matcher**
3. Generate command → **AI Command Generator**
4. Safety check → **Command Classifier**
5. If safe → **Execute immediately**
6. If risky → **Show approval prompt**
7. If blocked → **Deny with explanation**
8. Format results → **Result Formatter**
9. Show in chat → **Clean, readable output**

### Package Detection
```swift
// User: "download this video"
1. findPackageForQuery("download this video")
2. Match keywords: ["download", "video"]
3. Find: yt-dlp (Video Download default)
4. Check if installed: which yt-dlp
5. If not found → Offer to install
6. If found → Generate command
```

### GitHub Import Process
```swift
1. Extract repo: github.com/owner/repo
2. Fetch: GET api.github.com/repos/owner/repo/readme
3. Parse README:
   - Find "Installation" section
   - Extract: brew install X, cargo install X, etc.
   - Parse usage examples from code blocks
4. Create TerminalPackage
5. Add to configuration
```

---

## Future Enhancements
- [ ] **Multi-step workflows** with approvals
- [ ] **Smart result formatting** (tables, charts)
- [ ] **Package recommendations** based on queries
- [ ] **Command history learning**
- [ ] **Custom package repositories**
- [ ] **Progress indicators** for long commands
- [ ] **Command templates** for complex operations
- [ ] **Integration with system services**

---

*Last updated: 2026-03-01*

## User Experience

### Flow 1: Safe Commands (Auto-Execute)
**Example:** `update brew`

1. User types: `"update brew"` in L2 chat
2. L2 recognizes it as `brew update` (safe command)
3. **Command runs immediately in background terminal**
4. Chat shows: `✅ **Homebrew updated successfully**`
5. Full output appears in Terminal panel (if open)

**No confirmation needed** - safe commands execute automatically.

---

### Flow 2: Commands Requiring Approval
**Example:** `install yt-dlp`

1. User types: `"install yt-dlp"` in L2 chat
2. L2 generates command: `brew install yt-dlp`
3. **Chat shows approval prompt** (Claude-style):

```
Execute this command?

Using Homebrew

bash
brew install yt-dlp


Purpose: Install yt-dlp via Homebrew

[✓ Yes, Execute]  [✗ Cancel]
```

4. User clicks **"✓ Yes, Execute"**
5. Command runs in background terminal
6. Chat updates: `✅ **Command completed successfully**`
   `Check the Terminal panel for full output.`
7. Full installation output visible in Terminal panel

---

### Flow 3: Blocked Commands
**Example:** `rm -rf /`

1. User types dangerous command
2. L2 blocks it immediately
3. Chat shows: `⛔️ **Command blocked for safety**`
   `Reason: Would destroy system files`

---

## What Appears Where

### In Chat (L2 Messages)
- ✅ Simple success/completion messages
- ⚠️ Simple error notifications  
- 🤔 Approval prompts with Yes/Cancel buttons
- ⛔️ Blocked command warnings
- **NO full terminal output** (keeps chat clean)

### In Terminal Panel
- 📟 Live command execution
- 📊 Full output (stdout + stderr)
- 🕐 Execution time
- ✓ Exit codes
- 📝 Complete command history

---

## Command Classification

### Auto-Execute (Safe)
- Read-only commands: `ls`, `cat`, `pwd`, `git status`
- Info commands: `which`, `brew list`, `npm list`
- Package management: `brew update`, `brew upgrade`

### Requires Approval (Medium Risk)
- Installations: `brew install`, `npm install`
- Write operations: `mkdir`, `touch`, `cp`, `mv`
- Git writes: `git commit`, `git push`

### Blocked (Critical Risk)
- Destructive: `rm -rf`, `sudo rm`
- System modifications: `sudo`, `chown`
- Remote execution: `curl | bash`

---

## Configuration

### Terminal Settings (Settings → Terminal)
1. **Scan System** - Auto-detect installed tools
2. **Set Defaults** - Configure which package handles each task type
3. **Add Packages** - Manually add custom terminal tools

### Example: YouTube Downloader Setup
1. Install yt-dlp: `brew install yt-dlp`
2. Open Settings → Terminal → Scan System
3. Set "Video Download" default to "yt-dlp"
4. Now typing `"download current video"` in L2 uses yt-dlp automatically

---

## Natural Language Examples

### Auto-Execute (No Prompt)
```
User: "update brew"
L2: ✅ Homebrew updated successfully

User: "show git status"  
L2: ✅ Command completed successfully
     Check the Terminal panel for output.

User: "list installed packages"
L2: ✅ Package list ready
     Check the Terminal panel for details.
```

### With Approval
```
User: "download this video"
L2: Execute this command?
    
    yt-dlp https://youtube.com/watch?v=...
    
    Purpose: Download video using yt-dlp
    
    [✓ Yes, Execute]  [✗ Cancel]

After approval:
L2: ✅ Download completed successfully
    Check the Terminal panel for file location.
```

### Blocked
```
User: "delete all node_modules recursively"
L2: ⛔️ Command blocked for safety
    Reason: Recursive deletion is dangerous
    
    Alternative: Use Finder or delete specific folders
```

---

## Benefits

✅ **Clean Chat** - No verbose terminal output cluttering conversation
✅ **Full Control** - See everything in Terminal panel when needed
✅ **Safe** - Approval for risky commands, auto-block dangerous ones
✅ **Natural** - Just type what you want, L2 figures it out
✅ **Transparent** - Always shows what command will run
✅ **Context-Aware** - Uses current URL, selected files, etc.

---

## Technical Details

### Command Execution Path
1. User query → `L2UnifiedAssistant.parseIntent()`
2. Intent classification → `executeIntelligentTerminalQuery()`
3. Package matching → `TerminalPackageManager.findPackageForQuery()`
4. Command generation → `generateCommand()`
5. Safety check → `TerminalCommandClassifier.classify()`
6. If safe → execute directly
7. If risky → show approval prompt with actions
8. If blocked → deny with explanation
9. Execute → `TerminalAIBridge.processAICommand()`
10. Result → simple chat message + full terminal output

### Response Format
```swift
L2Response(
    message: "✅ Command completed successfully\n\nCheck Terminal for output",
    data: ["success": true],
    actions: [],  // or [Yes, Cancel] for approval
    suggestedFollowUps: []
)
```

---

## Future Enhancements
- [ ] Progress indicators for long commands
- [ ] Ability to cancel running commands
- [ ] Command output parsing for better summaries
- [ ] Learning from user approvals/denials
- [ ] Package-specific output formatting
- [ ] Multi-step workflow support with confirmations

---

*Last updated: 2026-03-01*

# Finder Pet Profile (`com.apple.finder`)

> **Scope ID:** `com.apple.finder`  
> **Pet Name:** Finder Assistant  
> **Focus Type:** `SurfaceFocus.pet("com.apple.finder")` or `SurfaceFocus.frontmost` (when Finder is frontmost).  
> **Implementation Reference:** `Context-Dock/AI/FinderContextGrounder.swift`, `Context-Dock/AI/AppPetIdentity.swift`, `Context-Dock/Search/DockCore+FinderAttachment.swift`.

---

## 1. Passive Grounding & Context Resolution

When the user queries the Finder Pet, `FinderContextGrounder` automatically resolves ambient filesystem context through a cascading 4-tier hierarchy before the model loop begins:

```
Tier 1: Explicit Selection (`selectedFilePaths` from AX / AppleScript)
  └─ If empty ──> Tier 2: Named Folder in User Query (e.g. "my Downloads folder")
                    └─ If not found ──> Tier 3: Active Open Window (frontmost Finder window target)
                                          └─ If no windows ──> Tier 4: Default Roots (~/Desktop or ~/)
```

### Inherent Directory Grounding
For directory contexts, `FinderContextGrounder` enumerates the directory tree and injects baseline metadata directly into `FinderGroundingOutcome`:
* `totalSizeBytes` & formatted string (e.g., `2.52 GB across 13,420 files`).
* Top-level file and subdirectory counts.
* Most recently modified files (last 5 entries).
* File extension distribution (e.g., `82% .png, 15% .pdf, 3% .txt`).

*Result:* Tool-free providers and lightweight models can answer questions like *"How big is this folder?"* or *"What files are in here?"* in a single turn without needing tool execution rounds.

---

## 2. The 5-Rung Execution Ladder for Finder

```
Rung 0: Solved Skills / Recipes (SolvedSkillStore)
  • "Clean up Downloads": move *.dmg to Trash, archive *.zip older than 30 days.
  • "Duplicate with Timestamp": copy file.ext -> file_YYYY-MM-DD.ext.

Rung 1: Direct Headless Data (AppleLiveDataContext / Spotlight)
  • MDQuery / NSMetadataQuery for fast file indexing by UTI or size.
  • Posix stat / FileManager reads for file permissions, sizes, and attributes.

Rung 2: Sandboxed AI Scripts (JXA / AppleScript)
  • AppleScript Finder suite for non-destructive operations:
    tell application "Finder" to set label index of (selection as alias) to 2

Rung 3: Native Menu Commands (find_menu_command)
  • File ▸ New Folder (⌘⇧N)
  • File ▸ Duplicate (⌘D)
  • File ▸ Move to Trash (⌘⌫)
  • View ▸ as Columns (⌘3)

Rung 4: Computer Use (Vision & AX Clicks)
  • Fallback only: dragging files between non-scriptable third-party drop zones.
```

---

## 3. Safety & Approval Gates

| Action Classification | Tool / Command | Gate Policy |
| :--- | :--- | :--- |
| **Safe Read** | Read directory, get file info, calculate size, search | `Auto-Approved` |
| **Safe Write** | Create new folder, tag file, duplicate file | `Auto-Approved` with `UndoReceipt` |
| **High-Risk Mutation** | Move to Trash, rename batch of files | `UndoReceipt` + visual toast |
| **Destructive / Permanent** | Permanent delete (`rm`), empty Trash, overwrite existing files | **Requires Explicit Approval Card** (`PendingApprovalJournal`) |

---

## 4. Error Traps & Self-Correction

1. **Path Not Found (`ENOENT` / AppleScript `-1728`):**  
   *Agent action:* Re-read the parent folder's contents to check for typo or case-sensitivity mismatch. Never create nested directories recursively without confirming intent.
2. **Permission Denied (`EACCES` / TCC Block):**  
   *Agent action:* If trying to access protected directories (`~/Library/Mail`, `~/Library/Messages`), advise the user to grant Full Disk Access to DoraX in `System Settings ▸ Privacy & Security`.

# Mail Pet Profile (`com.apple.mail`)

> **Scope ID:** `com.apple.mail`  
> **Pet Name:** Mail Assistant  
> **Focus Type:** `SurfaceFocus.pet("com.apple.mail")` or `SurfaceFocus.frontmost`.  
> **Implementation Reference:** `Context-Dock/AI/AppleLiveDataContext.swift` (`wantsMailContext`), `Context-Dock/Search/MailQuestionRouter.swift`, `docs/superpowers/specs/2026-11-08-issue-204-retire-mail-question-shortcut.md`.

---

## 1. Passive Grounding & Context Resolution

When Mail is active or addressed in conversation:
* **Selected Message Resolution:** Extracts subject, sender display name, sender email address, date, message body (plain text representation), and recipient list.
* **Slot Derivation (H0):** The `sender` context slot is **exclusively active** in Mail and Messages. In other apps, sender derivation stands down to prevent bogus context injection.
* **Mailbox State:** Active mailbox name (e.g. `Inbox`, `Flagged`, `Archive`) and unread count.
* **Freshness Heuristics:** Queries mentioning `"yesterday"`, `"did I receive"`, or `"from Sarah"` trigger `AppleLiveDataContext.wantsMailContext = true` to inject recent thread context directly into the prompt.

---

## 2. The 5-Rung Execution Ladder for Mail

```
Rung 0: Solved Skills / Recipes (SolvedSkillStore)
  • "Archive read newsletters": select newsletter folder, archive all read messages.
  • "Draft standard reply": compose template response with contextual recipient slots.

Rung 1: Direct Headless Data (AppleLiveDataContext / Spotlight Mail Index)
  • Search email headers and messages via Spotlight `kMDItemContentType == "com.apple.mail.emlx"`.
  • Direct thread extraction via ScriptingBridge / Apple Events.

Rung 2: Sandboxed AI Scripts (JXA / AppleScript)
  • Message composition and draft preparation:
    tell application "Mail"
      set newDraft to make new outgoing message with properties {subject:"...", content:"...", visible:true}
    end tell

Rung 3: Native Menu Commands (find_menu_command)
  • Message ▸ Reply (⌘R) / Reply All (⌘⇧R)
  • Message ▸ Archive (⌃⌘A)
  • Message ▸ Mark as Flagged (⌘⇧L)
  • Message ▸ Move to Junk (⌘⇧J)

Rung 4: Computer Use (Vision & AX Clicks)
  • Navigating custom Mail plugin sidebars or complex multipart attachment dialogs.
```

---

## 3. Safety & Approval Gates (Zero Accidental Sends)

Sending an email can damage personal or business relationships if executed erroneously or without review. DoraX enforces a **hard approval boundary**:

1. **Drafting is Safe (Rung 2/3):**  
   Preparing a draft, filling recipients, and opening the draft compose window (`visible: true`) is **auto-approved**. The user can inspect the message in Mail.
2. **Sending is Gated (Hard Approval):**  
   Calling `send message` or clicking the Send button **always requires an explicit approval card** (`PendingApprovalJournal`). The card displays:
   * **To / CC / BCC recipients**
   * **Subject line**
   * **Full body preview**
3. **Receipt Persisted:**  
   Once the user clicks "Send", an `ApprovalExecutionReceipt` is written before the AppleScript `send` command fires.

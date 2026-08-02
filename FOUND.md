# FOUND.md

Things noticed while working the security remediation that are **out of scope for the
item being fixed**. Recorded rather than fixed, per the remediation ground rule "do not
improve adjacent code".

Branch: `security-remediation`. Audit source: Context-Dock-REMEDIATION-PLAN.

---

## Audit items that were already done before this work started

- **Item 1 (auto-execute RCE)** — already fixed, and better than the audit proposed.
  `TerminalCommandClassifier.isCompoundOrControlCommand` (Services/TerminalCommandClassifier.swift:414)
  gates the safe-pattern allowlist on command *structure* — rejects `;`, `&&`, `||`, `|`,
  backtick, `$(`, `${`, `<(`, `>(`, redirects, `&`, newlines — plus `find`/`xargs`
  exec/delete primaries and a credential-path list (`.ssh`, `id_rsa`, `.env`, keychain…).
  All seven audit payloads are blocked. The audit's `return false` would have been a
  blunter fix that also killed `ls` auto-run.
- **Item 2 (`executeShellCommandSafely`)** — already deleted; only a NOTE comment remains
  at Search/LauncherView+AIResponseHandling.swift:822.
- **Item 11 (scope General Chat)** — already implemented, in a different file than the
  audit names. Context Dock scope routes `AICapabilityRegistry.promptBlock(for:)` →
  `AppWorkflowToolCatalog.promptBlock(for:)` → `scopedAdapters(bundleID:)`, which returns
  exact-bundle matches only. `GeneralChatCapabilityHub` only ever receives `.general` and
  `.selection` — its adapter union is correct product behaviour for those surfaces, and
  scoping it to the frontmost app would collapse General Chat into Context Dock, which the
  DoraX layer rule in CLAUDE.md forbids.

## Audit claims that are inaccurate

- **Item 7** says `AdapterActionType.riskLevel` "is used only for a badge colour" and that
  approval is not enforced. Approval *is* enforced: `AppAdapterManager.execute()` gates on
  `action.requiresApproval && !hasStandingGrant` (Services/AppAdapterManager.swift:338).
  What is still missing is the **escalation** half — a high-risk action whose author
  explicitly set `requiresApproval: false` still bypasses the sheet. Item 8 (done) fixed
  the *default*; the override is untouched.
- **Item 11** is framed as a sandbox escape. It is not — cross-app execution is already
  refused at run time by `CapabilityAuthorizationGate.validateTarget`
  (AI/AIOrchestrationModels.swift:150), which throws `crossAppDenied`. Any leak of this
  shape is a prompt-inventory/token issue, not an authority issue.
- Line numbers throughout the audit have drifted (item 7 cited :255, actual gate is :338;
  item 12 cited :250, correct at the time). The repo is 343 Swift files / ~181k lines vs
  the audit's 334 / 172k.

## Real issues found, not fixed

- **`get-task-allow` returns under xcodebuild's own Release signing.** Item 3 removed it
  from `Context-Dock/ILauncher.entitlements`, which is what `ship.sh` passes to raw
  `codesign --entitlements`, so the shipped DMG is clean (verified). But a plain
  `xcodebuild -configuration Release build` re-injects it from the automatic *development*
  provisioning profile — verified, along with `personal-information.addressbook` and
  `.location` that are not in the plist at all. If ship.sh ever stops signing manually, the
  entitlement silently comes back. Consider `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` for
  Release, or a Developer ID identity.

- **`Base.lproj/ILauncher.entitlements` is a stale duplicate** that still contains
  `com.apple.security.get-task-allow`. Nothing in `project.pbxproj` references it. It is
  inert today but is exactly the file someone edits by mistake later. Candidate for
  deletion.

- **Untrusted AX context reaches every L2 extension's environment.**
  `L2ExtensionManager.execute()` (AI/L2ExtensionManager.swift:216-220) injects
  `CURRENT_URL`, `WINDOW_TITLE` and `AX_SELECTED_TEXT` into the child process env. Env
  vars are not shell-interpreted so this is not an injection route, but it is hostile
  webpage content flowing into every script the user has installed. This is audit item 10
  (`containsUntrustedContent`) territory.

- **`GeneralChatCapabilityHub` MCP cache is query-dependent but not query-keyed.** The
  cached MCP block is built from `adapters`, which is filtered by `explicitlyNamed` —
  i.e. it depends on the *query* (AI/GeneralChatCapabilityHub.swift:82-86). The cache key
  is only the enabled-adapter fingerprint plus a 5-minute TTL, so a block computed for
  "what's in Obsidian" is served verbatim to an unrelated question for the next 5 minutes.
  The scope is also not part of the key.

## Deferred / not attempted

- **Item 5 (argv execution in TerminalAIBridge)** — the remaining Phase 2 security item and
  marked [HUMAN REVIEW] in the audit. Not started.
- **Item 7 escalation** — see above.
- **Items 4** (unpublish the beta DMG) is manual and outside the repo; `gh` is not
  installed on this machine.

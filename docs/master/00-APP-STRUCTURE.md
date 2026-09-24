# 00 — App Structure: where every piece of DoraX lives

> **Status: PROPOSAL — the target layout.** Companion to
> [`00-PRODUCT-PLAN.md`](00-PRODUCT-PLAN.md) (what to build) and
> [`00-CODEBASE-PLAN.md`](00-CODEBASE-PLAN.md) (rules + migration order).
> Every file named below exists today on `main` @ `341494a` unless marked **NEW**.

---

## 1. The idea in one picture

```
 ┌───────────────────────── Context-Dock (app target: UI only) ─────────────────────────┐
 │  App/        Shell/        Surfaces/Find   Surfaces/Ask   Surfaces/ActOnThis   Labs/ │
 │  Settings/   Onboarding/   Developer/                                                │
 └───────────────────────────────────────┬──────────────────────────────────────────────┘
                                          │  imports ↓ (never ↑)
        ┌─────────────────┬───────────────┼────────────────┬──────────────────┐
        ▼                 ▼               ▼                ▼                  │
   DoraXEngine     DoraXCapabilities   DoraXMemory                            │
   (think)         (do)                (remember)                             │
        └─────────────────┴───────┬───────┘                                   │
                                  ▼                                           │
                            DoraXContext  (see: AX, selection, web, apps)     │
                                  ▼                                           │
                            DoraXCore     (models, storage, keychain, logs) ◄─┘
```

Five words to remember: **Core → Context → Capabilities / Engine / Memory → App.**
Each layer only knows the ones **below** it.

---

## 2. Repository root

```
Context-Dock/                 ← repo
├── README.md  CHANGELOG.md  LICENSE  NOTICE  CLAUDE.md  AGENTS.md
├── Context-Dock.xcodeproj/
├── Context-Dock/             ← app target (§3)
├── Packages/                 ← local Swift packages (§4)
├── Context-DockTests/        ← app-level tests only (UI state, surfaces)
├── Context-DockExtension/    ← Safari Web Extension target
├── docs/
│   ├── master/               ← product map (00–10), the first thing to read
│   ├── architecture/         ← truth files (layers, rules)
│   ├── decisions/            ← DECISIONS.md, one entry per decision
│   ├── assets/               ← DoraXD.png, DoraXL.png, architecture PDF, HTML mockups
│   └── history/              ← PRERELEASE_AUDIT.md, FOUND.md, CONTEXT.md, old superpowers plans
├── scripts/                  ← dev-run, build, test, ship, make-dmg, check-file-size (NEW)
└── .github/                  ← workflows (build + test), PR template (NEW)
```

Leaves the root: the 18 MB `*.dmg` (→ GitHub Releases), `script/` (→ `scripts/`),
`CHANGES.md` (→ `CHANGELOG.md`), `Base.lproj/ILauncher.entitlements` (stale, delete),
loose `*.sh` helpers (→ `scripts/`), `ilauncher-api/` (→ `Packages/` or delete — `[?]` owner).

---

## 3. App target — `Context-Dock/` (only UI and wiring)

```
Context-Dock/
├── App/
│   ├── Lifecycle/       ILauncherApp.swift → split into AppDelegate.swift, WindowSetup.swift,
│   │                    Activation.swift · LaunchAtLoginHelper · ILauncherServicesProvider
│   ├── Routing/         AppRouter · AppState · NotificationNames
│   ├── Hotkeys/         DoubleModifierTap · hotkey code pulled out of ILauncherApp
│   └── DependencyContainer.swift     ← builds packages' services, hands them to surfaces
│
├── Shell/               ← the ONE Unified Dock Surface (shell, input, rows, size, animation)
│   ├── UnifiedDockSurface · LauncherShell · LauncherSurfaceContainers
│   ├── LauncherView.swift            ← becomes a thin router: which surface is showing
│   ├── Corner/          CornerDockWindow · CornerDockLayout · CornerKeyboardOwner ·
│   │                    CornerDockKeyboardState
│   ├── Layout/          DockMetrics · DockHeightPreset · DesignTokens · LiquidGlassArrow
│   └── Components/      ResultRow · AppToast · AppBundleIconView · AIProviderIcon ·
│                        FileThumbnailImage · SFSymbolPickerView · QuickLookPreview
│
├── Surfaces/
│   ├── Find/                                         (docs 01 + 02)
│   │   ├── GlobalContext/  GlobalContextSurface · GlobalContextTypingModel · GlobalContextRow ·
│   │   │                   PinnedAppsRow · CornerDockStrip · CornerWindowRow ·
│   │   │                   FindModel.swift (NEW — owns the @State now in LauncherView+Search*)
│   │   ├── ContextDock/    ContextDockSurface · ContextDockPillCoordinator · FrontmostMenuMatcher ·
│   │   │                   ContextDockModel.swift (NEW)
│   │   └── Finder/         FinderContextViewModel · FinderSemanticModels
│   │
│   ├── Ask/                                          (docs 03 + 04)
│   │   ├── Dock/           ContextDockChatSurface · GeneralChatSurface · CornerGeneralChatView ·
│   │   │                   CornerChatPresentation · AppChatPromptPill · AppChatListCard
│   │   ├── Window/         GeneralChatWindowController · GeneralChatWindowView ·
│   │   │                   GeneralChatWindowChrome · GeneralChatWindowModel ·
│   │   │                   GeneralChatStartView · AppScopedStartView
│   │   └── Components/     ApprovalCard · CapabilityGapCard · ChatClarificationCard ·
│   │                       ChatAttachmentChip · LiveAgentProgressView · LiveAgentStepsView ·
│   │                       AIMessageViews · FileChangesApprovalView · ChatSlashAppPicker
│   │
│   ├── ActOnThis/                                    (doc 05)
│   │   ├── Selection/      SelectionScopeModel · SelectionScopeCard · ExtensionScopeCard ·
│   │   │                   AppChatSelectionScope
│   │   └── Clipboard/      ClipboardPanelWindow · ClipboardPreviewCard ·
│   │                       ClipboardPreviewScratchFile · ClipboardModel.swift (NEW)
│   │
│   ├── Preview/            today's Preview/ folder (shared file preview, used by Find + ActOnThis)
│   │
│   └── Labs/               ← off by default in v1 (Settings → Labs)
│       ├── MediaDock/      MediaDockSurface · MiniPlayerOverlay
│       ├── Dashboard/      today's UI/Dashboard/*
│       ├── DropShelf/      DropShelfWindow · DropShelfPill · DropShelfPresentation
│       └── Notepad/        NotepadScopeView
│
├── Settings/
│   ├── SettingsWindow.swift
│   ├── Pages/              one file per page: General · Hotkeys · Providers · Apps & Adapters ·
│   │                       Permissions · Privacy · Memory · Labs · Updates · About
│   └── Legacy/             LegacySettingsContent · AutomationSettingsView (emptied page by page,
│                           then deleted)
│
├── Onboarding/  (NEW)      Welcome · PermissionStep · ProviderStep · FirstTaskStep
├── Developer/              Inspector* (compiled in Debug only)
└── Resources/              Assets.xcassets · Info.plist · ILauncher.entitlements
```

**The 39 `LauncherView+*.swift` files** dissolve into the surface they serve. Mapping:

| Today | Goes to |
|---|---|
| `+Search`, `+SearchBar`, `+SearchResults`, `+GlobalContextActions`, `+GlobalAppDock`, `+PinnedResults`, `+KeyboardNavigation` | `Surfaces/Find/GlobalContext/` (state → `FindModel`) |
| `+ContextDockPills`, `+ContextualActions`, `+ContextActionsUI`, `+DockAppActions`, `+DockBase`, `+DockHeight`, `+ContextDockAppSwitching`, `+MailFindActions` | `Surfaces/Find/ContextDock/` |
| `+FinderAttachment`, `+FinderBrowse`, `+FinderContextualActions`, `+FinderSemantic` | `Surfaces/Find/Finder/` |
| `+AIChat`, `+AIResponseHandling`, `+GeneralAIActions`, `+GeneralChatAppSlash`, `+RemPanelChat`, `+LiveProgress`, `+LivePanel` | `Surfaces/Ask/Dock/` |
| `+SelectionRouter`, `+ShareActions` | `Surfaces/ActOnThis/Selection/` |
| `+ClipboardScope` | `Surfaces/ActOnThis/Clipboard/` |
| `+L2UnifiedDockRow`, `+L2QueryHandling` | `Surfaces/Labs/MediaDock/` or delete with the old brain |
| `+ContextDetection`, `+ContextLifecycle`, `+InteractionLifecycle`, `+StateBridges`, `+Utilities`, `+PreviewHelpers`, `+BrowserPageActions`, `+Safari` | `Shell/` (only what the shell itself needs), the rest into the surface that calls it |

---

## 4. Packages — `Packages/` (no SwiftUI views, no `LauncherView`)

### 4.1 `DoraXCore` — shared vocabulary. Depends on nothing.
```
Sources/DoraXCore/
├── Models/       UserContext · ContextSnapshot · DataSubject · ClipboardEntry (moved out of
│                 LauncherView) · SearchResult models · DoraXActionReceipt
├── Storage/      ContextDockStore · StorageFacades · SettingsBackupManager
├── Security/     KeychainStore
├── Settings/     AppSettings (the stored values, not the UI)
├── Logging/      DoraXTurnLog · DebugLogger · SearchPerformanceLog
└── Concurrency/  AsyncTimeout · ResumeOnceGuard · CancellableProcess · BackgroundWorkerPool
```

### 4.2 `DoraXContext` — what DoraX can *see*. Depends on Core.
```
Sources/DoraXContext/
├── Accessibility/  AXObserverManager · AXEventBus · AXContextReader · AXMenuReader ·
│                   AXMenuEnumerator · AXSelectionObserver · AXActionResolver · AXWindowControl …
├── Detection/      ContextDetector · ContextEngineProtocol · SelectedContextResolver ·
│                   AppWindowSnapshotService · ProjectContextResolver
├── Web/            AXWebReader · SafariTabManager · SafariDeepContext* · WebContextEngine
└── Apps/           InstalledApplicationsCatalog · AppCatalogService · RecentItemsService ·
                    AppUsageLearner · ProcessMonitorService
```

### 4.3 `DoraXCapabilities` — what DoraX can *do*. Depends on Core, Context.
```
Sources/DoraXCapabilities/
├── Registry/     CapabilityIndex · CapabilityCatalog · AICapabilityRegistry ·
│                 CapabilityScopeGuard · AppAccessLevel · CapabilityAvailabilityStore
├── Menus/        AppMenuCapabilityCache · MenuExecutionCoordinator · MenuWarmCacheService ·
│                 LiveMenuHistoryCache · MenuShortcutFormatter
├── Adapters/     AppAdapterManager · AppAdapterContract · Adapter*Seeder · AdapterPackImporter ·
│                 AdapterActionConsentStore
├── MCP/          MCPClient · MCPRuntime · MCPServerManager · DoraXMCPServer ·
│                 Apple{Calendar,Contacts,Mail,Messages,Music,Notes,Photos,Reminders}MCPCapabilities
├── AppleApps/    EventKitTools · AppleNotes* · ContactSearchManager · Messages* · MailAutomation
├── Finder/       FinderActionService · FinderToolkit · Finder*Capabilities · FileIndexManager
├── Terminal/     TerminalCommandExecutor · TerminalCommandClassifier · TerminalPackageManager ·
│                 ArgvCommandGate · CLILinkTrustStore
├── Shortcuts/    ShortcutsCatalog · ShortcutRunner
├── Extensions/   BuiltInExtensions · ExtensionManager · L2ExtensionManager · UserGlobalExtensionStore
├── Search/       GlobalSearchService · GlobalContextEngine · GlobalContextSearchCoordinator
└── Media/        MediaRemoteBridge · MediaDockEngine · MediaPlayerObserver   (Labs)
```

### 4.4 `DoraXEngine` — how DoraX *thinks*. Depends on Core, Context, Capabilities, Memory.
```
Sources/DoraXEngine/
├── Providers/     today's AI/Providers/* · AIProviderRouter · AIProviderService ·
│                  AnthropicModelCatalog · GeminiModelCatalog · OnDeviceToolBridge
├── Grounding/     ScopedAppPromptBuilder · ScopedGroundingBlocks · ScopedPromptAssembler ·
│                  AIContextBudget · UntrustedContent · GeneralChatLocalEvidence
├── Routing/       AIRequestClassifier · GeneralChatScopeResolver · GeneralAIActionResolver ·
│                  ChatRouteResolver · MenuIntentRouter · CrossAppRouter
├── Loop/          AgentToolRegistry · ScopedTurnRunner · TaskRunStore · AIToolBudget ·
│                  ReadingTools · RouteTools
├── Planner/       ChatPlan · WorkflowRecipe · WorkflowAuthor
├── Verification/  AgentAnswerVerifier · CommandOutcomeVerifier · MenuOutcomeVerifier ·
│                  VerificationStatus · ActionVerifierRegistry
├── Safety/        ApprovalCenter (decision logic; the card UI stays in Ask/Components) ·
│                  AISafetyPolicy · AIOrchestrationPolicy
├── Cost/          AITokenLedger · AIModelRateCard · AnthropicPromptCache
├── Workers/       today's AI/Workers/* · ClaudeCodeCLIService · CodexCLIService   (Labs)
└── Chat/          AppScopedChatService · GeneralChatSessionStore · AppPanelChatStore
```

### 4.5 `DoraXMemory` — what DoraX *remembers*. Depends on Core.
```
Sources/DoraXMemory/
  MarkdownMemoryStore · BrainProfile · ConversationDistiller · DailyBrief · BrainMaintenance ·
  QuickNoteMemoryMirror · QuickNotesStore
```

Each package has `Tests/<Package>Tests/` and a 10-line `README.md`: its job, its public API,
and what it must never import.

### 4.6 To delete, not move
`L2UnifiedAssistant` · `L2WorkflowEngine` · `L2AIIntegrationView` · `L2GitHubBridge` ·
`L2GitHubToolIntegration` — **after** `turns.log` proves `GeneralAIActionResolver` is the live
router (`04 §10 #1`). Plus whatever in `LegacySettingsContent` nothing reaches.

---

## 5. "Where does my new file go?" — the decision rule

Ask these in order; the first **yes** wins:

1. Does it draw pixels (a SwiftUI `View`, a window)? → **app target**, in the surface that shows it
   (`Surfaces/<Verb>/…`), or `Shell/Components/` if two or more surfaces use it.
2. Does it talk to a model provider, build a prompt, or decide a route? → **DoraXEngine**
3. Does it perform an action in another app, or run a command/MCP/Shortcut? → **DoraXCapabilities**
4. Does it read what is on screen / selected / frontmost? → **DoraXContext**
5. Does it write to or read from the memory vault? → **DoraXMemory**
6. Is it a plain model, store, or utility with no opinion? → **DoraXCore**

If a file seems to need two answers, it is two files.

---

## 6. Naming

| Kind | Pattern | Example |
|---|---|---|
| Surface screen | `<Surface><Thing>View` | `FindResultsView` |
| Surface state | `<Surface>Model` (`@Observable`) | `ClipboardModel` |
| Engine/capability service | noun, no `Manager` for new code | `MenuExecutor`, not `MenuExecutionManager` |
| Protocol at a package edge | `<Thing>Providing` | `ContextProviding` |
| Test file | `<Type>Tests` / `<Area>EvalTests` | `CapabilityIndexTests` |
| Retired prefixes | no new `ILauncher*`, `L2*`, `LauncherView+*` | — |

---

## 7. How this relates to the rules you already have

| Existing rule (CLAUDE.md / architecture) | Where the structure makes it real |
|---|---|
| "Never merge product layers" | One folder per surface under `Surfaces/`; surfaces cannot import each other's models |
| "AppDelegate never imports Search or AI types" | `App/` talks only to `DependencyContainer` and packages' protocols |
| "Unified Dock Surface: one shell" | Exactly one `Shell/` folder; surfaces provide content, never windows |
| "Reading context → `ContextEngineProtocol`" | The protocol lives in `DoraXContext`; surfaces receive it via `DependencyContainer` |
| "Media Dock is not a chat surface" | `Labs/MediaDock` cannot reach `Ask/` — different folder, no shared model |

---

*How to get from today to this layout, safely and in order: [`00-CODEBASE-PLAN.md`](00-CODEBASE-PLAN.md) §4.*

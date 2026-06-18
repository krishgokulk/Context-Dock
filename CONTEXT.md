# Context-Dock — AI Context Snapshot
Generated: 2026-06-18 02:33

## App overview
macOS 26 launcher and dock-replacement app.
Bundle: com.krishgokul.ContextDock
Swift 5, SwiftUI, macOS 26.1 minimum, 265+ Swift files.
Targets: Context-Dock (main), Context-DockExtension (Safari), SwiftTerm (terminal).

## DoraX architecture rules — NEVER violate
- Global Context, Chat Mode, Context Dock, Selection Sheet, Media Dock are separate surfaces.
- Each surface has ONE job. Never merge layers.
- Unified Dock Shell: one container, multiple modes. No separate floating windows per mode.
- Architecture truth lives in docs/architecture/

## Folder rules — new files must go here
App/           entry point, AppSettings, AppState, AppRouter, launch helpers
AI/Providers/  AI adapters (Anthropic, OpenAI, Gemini, Ollama, OpenAI-compatible)
Accessibility/ AX observer, AXEventBus, context snapshots
Automation/    cross-app routing, menu intent, app-specific macros
Search/        LauncherView, surfaces, coordinators, dock rows, pill system
Services/      shared infrastructure (context, media, file, extensions)
UI/Settings/   settings pages only
UI/            reusable components (overlays, toasts, panels)

## All Swift files by folder

### App/ (9 files)
App/AppRouter.swift
App/AppSettings.swift
App/AppState.swift
App/DependencyContainer.swift
App/ILauncherApp.swift
App/ILauncherNotificationManager.swift
App/ILauncherServicesProvider.swift
App/LaunchAtLoginHelper.swift
App/NotificationNames.swift

### AI/ (39 files)
AI/AICapabilityRegistry.swift
AI/AIChatEngine.swift
AI/AIContextBuilder.swift
AI/AIModeView.swift
AI/AIProfileModels.swift
AI/AIProfileRouter.swift
AI/AIProfileStore.swift
AI/AIProviderRouter.swift
AI/AIProviderService.swift
AI/AIRequestBuilder.swift
AI/AIResultExplanationService.swift
AI/AIResultViewer.swift
AI/AISafetyPolicy.swift
AI/AIShortcutMatcher.swift
AI/AITerminalPrompts.swift
AI/FinderFileChangeCapabilities.swift
AI/GitCapabilities.swift
AI/L2AIFileManager.swift
AI/L2AIIntegrationView.swift
AI/L2AITaskExecutor.swift
AI/L2AppActionRouter.swift
AI/L2ExtensionManager.swift
AI/L2ExtensionUIViews.swift
AI/L2GitHubBridge.swift
AI/L2GitHubToolIntegration.swift
AI/L2IntentSystem.swift
AI/L2SemanticResolver.swift
AI/L2UnifiedAssistant.swift
AI/L2WorkflowEngine.swift
AI/Providers/AIProviderToolHTTP.swift
AI/Providers/AIProviderToolLoops.swift
AI/Providers/AnthropicToolProviderAdapter.swift
AI/Providers/GeminiToolProviderAdapter.swift
AI/Providers/OllamaToolProviderAdapter.swift
AI/Providers/OpenAICompatibleModelDiscovery.swift
AI/Providers/OpenAICompatibleToolProviderAdapter.swift
AI/Providers/OpenAIToolProviderAdapter.swift
AI/TailscaleCapabilities.swift
AI/XcodeCapabilities.swift

### Accessibility/ (12 files)
Accessibility/AXActionResolver.swift
Accessibility/AXContextReader.swift
Accessibility/AXEventBus.swift
Accessibility/AXMenuEnumerator.swift
Accessibility/AXMenuReader.swift
Accessibility/AXObserverManager.swift
Accessibility/AXSearchFieldInjector.swift
Accessibility/AXSelectionObserver.swift
Accessibility/AXTriggerRule.swift
Accessibility/AXTriggerRuleEngine.swift
Accessibility/AXTriggerRuleSettingsView.swift
Accessibility/AXWebReader.swift

### Automation/ (13 files)
Automation/APICommandHandler.swift
Automation/AppContentSearchRouter.swift
Automation/AutomationEngine.swift
Automation/AutomationMigrationHelper.swift
Automation/AutomationSettingsView.swift
Automation/CommandApprovalView.swift
Automation/CrossAppNLHandler.swift
Automation/CrossAppRouter.swift
Automation/MailAutomation.swift
Automation/MenuIntentRouter.swift
Automation/MessagesAutomation.swift
Automation/ShareDestinationResolver.swift
Automation/ShareIntentRouter.swift

### Search/ (64 files)
Search/AIMessageViews.swift
Search/ContactPreviewViews.swift
Search/ContentView.swift
Search/ContextDockChatSurface.swift
Search/ContextDockPillCoordinator.swift
Search/ContextDockSurface.swift
Search/DockHeightPreset.swift
Search/DockModels.swift
Search/FeatureViewModels.swift
Search/FileThumbnailImage.swift
Search/FinderContextViewModel.swift
Search/FinderSemanticModels.swift
Search/FolderPreviewViews.swift
Search/FuzzyMatcher.swift
Search/GeneralChatSurface.swift
Search/GlobalContextSurface.swift
Search/L2UnifiedDockRowSurface.swift
Search/LauncherInfrastructure.swift
Search/LauncherShell.swift
Search/LauncherState.swift
Search/LauncherSupportViews.swift
Search/LauncherSurfaceContainers.swift
Search/LauncherUIUtilities.swift
Search/LauncherView+AIChat.swift
Search/LauncherView+AIResponseHandling.swift
Search/LauncherView+ClipboardScope.swift
Search/LauncherView+ContextActionsUI.swift
Search/LauncherView+ContextDetection.swift
Search/LauncherView+ContextDockAppSwitching.swift
Search/LauncherView+ContextDockPills.swift
Search/LauncherView+ContextLifecycle.swift
Search/LauncherView+ContextualActions.swift
Search/LauncherView+DockAppActions.swift
Search/LauncherView+DockBase.swift
Search/LauncherView+DockHeight.swift
Search/LauncherView+FinderAttachment.swift
Search/LauncherView+FinderContextualActions.swift
Search/LauncherView+FinderSemantic.swift
Search/LauncherView+GlobalAppDock.swift
Search/LauncherView+GlobalContextActions.swift
Search/LauncherView+InteractionLifecycle.swift
Search/LauncherView+KeyboardNavigation.swift
Search/LauncherView+L2QueryHandling.swift
Search/LauncherView+L2UnifiedDockRow.swift
Search/LauncherView+LivePanel.swift
Search/LauncherView+MailFindActions.swift
Search/LauncherView+PinnedResults.swift
Search/LauncherView+PreviewHelpers.swift
Search/LauncherView+RemPanelChat.swift
Search/LauncherView+Safari.swift
Search/LauncherView+Search.swift
Search/LauncherView+SearchBar.swift
Search/LauncherView+SearchResults.swift
Search/LauncherView+ShareActions.swift
Search/LauncherView+StateBridges.swift
Search/LauncherView+Utilities.swift
Search/LauncherView.swift
Search/MediaDockSurface.swift
Search/NotificationViews.swift
Search/ResultRow.swift
Search/SearchResult.swift
Search/SelectionCommandBuilder.swift
Search/SelectionShortcutCoordinator.swift
Search/SystemExtensionActionSource.swift

### Services/ (89 files)
Services/AppAdapterManager.swift
Services/AppCatalogService.swift
Services/AppInteractionStore.swift
Services/AppMenuCapabilityCache.swift
Services/AppPanelChatStore.swift
Services/AppScopeMatchCache.swift
Services/AppSuggestionsDB.swift
Services/AppUsageLearner.swift
Services/AppleAppsAPI.swift
Services/BackgroundWorkerPool.swift
Services/BinaryWatcherService.swift
Services/BluetoothDeviceProvider.swift
Services/BuiltInExtensions.swift
Services/CodeSuggestionSaver.swift
Services/ContactSearchManager.swift
Services/ContextDetector.swift
Services/ContextDockEngine.swift
Services/ContextDockPillBuilder.swift
Services/ContextDockStore.swift
Services/ContextEngineProtocol.swift
Services/ContextServices.swift
Services/ContextSnapshot.swift
Services/DebugLogger.swift
Services/DefaultAppResolver.swift
Services/DockActionFeedback.swift
Services/DoraXSpotlightIndexService.swift
Services/EventKitTools.swift
Services/ExtensionArchitecture.swift
Services/ExtensionManager.swift
Services/ExtensionModels.swift
Services/ExtensionScanner.swift
Services/FileIndexManager.swift
Services/FileSystemWatcher.swift
Services/FileTypeToolRegistry.swift
Services/FinderActionService.swift
Services/FinderContextualMenuActionSource.swift
Services/FinderToolkit.swift
Services/GlobalContextEngine.swift
Services/GlobalContextSearchCoordinator.swift
Services/GlobalSearchService.swift
Services/InstalledApplicationsCatalog.swift
Services/IntelligentExtensionMatcher.swift
Services/KeychainStore.swift
Services/LayeredExtensionManager.swift
Services/ManifestGenerationService.swift
Services/MediaDockEngine.swift
Services/MediaInfoProvider.swift
Services/MediaPlayerObserver.swift
Services/MediaRemoteBridge.swift
Services/MenuExecutionCoordinator.swift
Services/MenuShortcutFormatter.swift
Services/MenuWarmCacheService.swift
Services/MetadataResolver.swift
Services/OnDeviceStructuredStubs.swift
Services/OnDeviceToolBridge.swift
Services/PromptRunner.swift
Services/QueryFailureGuide.swift
Services/QueryIntentCache.swift
Services/RecentItemsService.swift
Services/SFSymbolResolver.swift
Services/SafariBrowserBridge.swift
Services/SafariCommandBridge.swift
Services/SafariDeepContextStubs.swift
Services/SafariLinkResolver.swift
Services/SafariRecentURLService.swift
Services/SafariTabManager.swift
Services/SearchPerformanceLog.swift
Services/SelectedContextResolver.swift
Services/SettingsBackupManager.swift
Services/ShareActionCoordinator.swift
Services/ShortcutRunner.swift
Services/ShortcutsCatalog.swift
Services/StorageFacades.swift
Services/SystemCommandInteractiveSupport.swift
Services/SystemCommands.swift
Services/SystemDataSearchManager.swift
Services/TerminalAIBridge.swift
Services/TerminalCommandClassifier.swift
Services/TerminalCommandPreferences.swift
Services/TerminalPackageManager.swift
Services/TerminalToolDiscovery.swift
Services/ThumbnailGenerator.swift
Services/ToolManifestDB.swift
Services/UninstalledAppCleanupService.swift
Services/UsageTracker.swift
Services/UserContext.swift
Services/WebResearchSession.swift
Services/WiFiNetworkProvider.swift
Services/WindowManagementService.swift

### UI/ (38 files)
UI/AppBundleIconView.swift
UI/AppToast.swift
UI/BrewInstallButton.swift
UI/ContextDockGlyph.swift
UI/DesignTokens.swift
UI/FileChangesApprovalView.swift
UI/GitHubToolView.swift
UI/LegacySettingsContent.swift
UI/MiniPlayerOverlay.swift
UI/PinnedAppsRow.swift
UI/QuickLookPreview.swift
UI/SFSymbolPickerView.swift
UI/SelectionCommandSheetView.swift
UI/Settings/AIProvidersSettingsPage.swift
UI/Settings/AboutSettingsPage.swift
UI/Settings/AdvancedSettingsPage.swift
UI/Settings/AppearanceSettingsPage.swift
UI/Settings/DataStorageSettingsPage.swift
UI/Settings/ExtensionsSettingsPage.swift
UI/Settings/GeneralSettingsPage.swift
UI/Settings/HotkeysSettingsPage.swift
UI/Settings/MediaActionsSettingsPage.swift
UI/Settings/PermissionsSettingsPage.swift
UI/Settings/SettingsChromeState.swift
UI/Settings/SettingsDetailView.swift
UI/Settings/SettingsModels.swift
UI/Settings/SettingsSidebar.swift
UI/Settings/SettingsView.swift
UI/Settings/UpdatesSettingsPage.swift
UI/ShortcutMenuCommand.swift
UI/ShortcutSheetPanelPresenter.swift
UI/ShortcutSheetView.swift
UI/SystemCommandAccessoryView.swift
UI/SystemPermissionsSettingsView.swift
UI/TerminalView.swift
UI/ToolInstallSheet.swift
UI/UnifiedDockSurface.swift
UI/WebQuickLookPanel.swift

## Recent commits (last 10)
- 0f72b05 refactor: extract coordinators, surfaces, and service layers (31 minutes ago)
- f6690d2 chore: add Claude Code skills for Context-Dock development (2 days ago)
- 06950d8 refactor: complete cutover to UnifiedDockShell (Step 5/5) (3 days ago)
- f4ba144 refactor: wire dockPills to surfaces (Step 4/5) (3 days ago)
- cb9cee7 refactor: integrate UnifiedDockShell with feature flag (Step 3/5) (3 days ago)
- 73c5003 refactor: wire surfaces to data flow (Step 2/5) (3 days ago)
- d73ca84 refactor: extract unified dock shell + mode surfaces (3 days ago)
- 62abf4a feat: update app icon to DoraX logo (3 days ago)
- 5c0788d fix: debounce AX selection rebuilds, move MainActor sleeps to background, clear AX observers on sleep/wake (4 days ago)
- b21ea65 fix: hotkey re-registration on settings change now unregisters all three hotkeys (4 days ago)

## CHANGES.md (last 30 lines)
(no CHANGES.md yet)

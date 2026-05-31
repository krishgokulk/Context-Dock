# Context Dock Architecture Release Map

## Release-Safe Boundaries Added

App:
- `AppState`
- `AppRouter`
- `DependencyContainer`
- `LauncherShell`

Feature boundaries:
- `GlobalContextEngine`
- `ContextDockEngine`
- `MediaDockEngine`
- `AIChatEngine`
- `AutomationEngine`
- feature ViewModels

Extension pipeline:

```text
User action
  -> ExtensionContext.collect
  -> ExtensionMatcher.matching
  -> ExtensionRunner.execute
  -> ExtensionAIAdapter (only when AI required)
  -> AIProviderRouter
  -> selected provider adapter
  -> AIProviderService
```

Storage facades:
- `ContextDockStore`
- `CacheStore`
- `ExtensionStore`
- `SettingsStore`
- `AutomationRuleStore`

Shared context facades:
- `SelectionContextService`
- `FrontmostAppContextService`
- `BrowserContextService`
- `MediaContextService`

## Release Rule

Do not move large `LauncherView` blocks immediately before distribution. Existing behavior stays stable behind new facades.

## Post-Release Extraction Queue

1. Move search bar rendering from `LauncherView` into `LauncherSearchBar`.
2. Move integrated results sheet into `ResultsPanelView`.
3. Move Global Context rendering into `GlobalContextView`.
4. Move Context Dock rendering into `ContextDockView`.
5. Move Media Dock rendering into `MediaDockView`.
6. Move AI chat rendering into `AIChatPanelView`.
7. Move live terminal/results panel into `LivePanelView`.
8. Replace direct legacy extension execution call sites with `ExtensionRunner`.
9. Replace direct AI call sites outside `AIProviderService` with `AIProviderRouter`.
10. Add archive validation: Developer ID signing, notarization, Gatekeeper open test on clean Mac.

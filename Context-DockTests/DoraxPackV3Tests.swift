// Context-DockTests/DoraxPackV3Tests.swift
//
// Comprehensive unit & integration tests for Steps 1–6 of the .doraxpack v3 Master Plan:
// - Step 2: Safe .zip backup + legacy cleanup, migrated first-party packs
// - Step 3: Pack v3 schema/validator, Keychain prefs, permission-gated $DORAX_CONTEXT,
//           dorax.* native sources, stale-while-revalidate runtime, logs, @pack mentions,
//           and flagship ProcessMonitor.doraxpack execution
// - Step 4: DockAuraEngine (hex parsing, Reduce Motion, priority) + Notch Live Activities
// - Step 5: Frontmost App + Web-App domain scope ranking, Hook Dispatcher (3 guardrails),
//           and strict argv-only mode: cli
// - Step 6: Context-aware DoraxPackV3Builder ("Create for <App / Web-App>") & templates

import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct DoraxPackV3Tests {

    // MARK: - Step 2: Safe .zip Backup & Legacy Cleanup

    @Test("LegacyPluginCleanup zips existing legacy clutter before removing it and keeps non-legacy files")
    func legacyCleanupBacksUpAndRemoves() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorax-legacy-test-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }

        // Seed legacy files/folders
        let globalExt = root.appendingPathComponent("global/extensions.json")
        let l1Dir = root.appendingPathComponent("Extensions/L1-Search", isDirectory: true)
        let storePacks = root.appendingPathComponent("plugins/store-packs", isDirectory: true)
        let currencyDir = root.appendingPathComponent("plugins/essentials/plugins/currency", isDirectory: true)
        let keepFile = root.appendingPathComponent("global/rules.json")

        try fm.createDirectory(at: globalExt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: l1Dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: storePacks, withIntermediateDirectories: true)
        try fm.createDirectory(at: currencyDir, withIntermediateDirectories: true)

        try Data("[]".utf8).write(to: globalExt)
        try Data("legacy".utf8).write(to: l1Dir.appendingPathComponent("old.json"))
        try Data("store".utf8).write(to: storePacks.appendingPathComponent("pack.json"))
        try Data("fx".utf8).write(to: currencyDir.appendingPathComponent("manifest.json"))
        try Data("keep-me".utf8).write(to: keepFile)

        let report = LegacyPluginCleanup.runBackupAndCleanup(appSupportRoot: root)
        #expect(report.succeeded)
        #expect(report.didCleanAnything)
        let zipURL = try #require(report.backupZipURL)
        #expect(fm.fileExists(atPath: zipURL.path))
        let attrs = try fm.attributesOfItem(atPath: zipURL.path)
        let zipSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        #expect(zipSize > 0)

        // Legacy items removed, non-legacy file untouched
        #expect(!fm.fileExists(atPath: globalExt.path))
        #expect(!fm.fileExists(atPath: l1Dir.path))
        #expect(!fm.fileExists(atPath: storePacks.path))
        #expect(!fm.fileExists(atPath: currencyDir.path))
        #expect(fm.fileExists(atPath: keepFile.path))

        // Second run is a clean idempotent no-op
        let second = LegacyPluginCleanup.runBackupAndCleanup(appSupportRoot: root)
        #expect(second.succeeded)
        #expect(!second.didCleanAnything)
        #expect(second.backupZipURL == nil)
    }

    @Test("Currency is retired from PluginEssentials.all and disabled provider:custom samples are filtered from live SystemCommands")
    func legacySeedCleanup() {
        #expect(!PluginEssentials.all.contains(where: { $0.id == "currency" }))
        #expect(PluginEssentials.all.contains(where: { $0.id == "sleep" }))
        let disabledCustom = SystemCommandsRegistry.shared.commands.filter { !$0.isEnabled && $0.provider == "custom" }
        #expect(disabledCustom.isEmpty)
    }

    // MARK: - Step 2 & 3: First-Party Migrated Packs + Flagship ProcessMonitor Pack

    @Test("All 5 first-party packs + ProcessMonitor flagship pack load cleanly as v3 with 0 validation errors")
    func allShippedPacksValidV3() throws {
        let packsDir = try #require(FirstPartyPacks.resolvePacksDirectory())
        let packURLs = DoraxPackV2Loader.discoverPacks(in: packsDir)
        let loaded = try packURLs.map { try DoraxPackV2Loader.load(from: $0) }
        let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })

        for id in ["finder", "safari", "mail", "iina", "antigravity", "process-port-monitor"] {
            let pack = try #require(byID[id], "Missing shipped pack \(id)")
            #expect(pack.metadata.schemaVersion == 3)
            #expect(pack.metadata.isV3)
            let errors = DoraxPackV3Validator.validate(pack).filter { $0.severity == .error }
            #expect(errors.isEmpty, "\(id) errors: \(errors.map(\.message))")
        }
    }

    @Test("Flagship ProcessMonitor pack executes live list, grid, form, notch commands and headless tool")
    func flagshipProcessMonitorRunsLive() async throws {
        let packsDir = try #require(FirstPartyPacks.resolvePacksDirectory())
        let pmURL = packsDir.appendingPathComponent("ProcessMonitor.doraxpack", isDirectory: true)
        let pack = try DoraxPackV2Loader.load(from: pmURL)
        let runtime = DoraxPackV3Runtime()

        let commands = try #require(pack.metadata.commands)
        let topCmd = try #require(commands.first { $0.id == "top-processes" })
        let topResult = await runtime.runCommand(topCmd, in: pack, forceRefresh: true)
        let topOut = try topResult.get()
        #expect(!topOut.items.isEmpty)
        let firstProc = try #require(topOut.items.first)
        #expect(!firstProc.accessories.isEmpty)
        #expect(firstProc.detail != nil)
        #expect(firstProc.actions.contains(where: { $0.destructive && $0.confirmMessage != nil }))
        #expect(!runtime.logs(for: pack.id).isEmpty)

        // Grid mode
        let gridCmd = try #require(commands.first { $0.id == "system-overview" })
        let gridOut = try await runtime.runCommand(gridCmd, in: pack, forceRefresh: true).get()
        #expect(gridOut.items.count == 4)

        // Form mode
        let formCmd = try #require(commands.first { $0.id == "port-inspector" })
        let formOut = try await runtime.runCommand(
            formCmd, in: pack, formValues: ["port": "59999"], forceRefresh: true
        ).get()
        #expect(formOut.detail?.markdown.contains("59999") == true)

        // Notch mode
        let notchCmd = try #require(commands.first { $0.id == "notch-monitor" })
        let notchOut = try await runtime.runCommand(notchCmd, in: pack, forceRefresh: true).get()
        #expect(notchOut.notch?.wingText.isEmpty == false)
        DynamicNotchState.shared.dismissPackActivity()

        // Headless AI tool
        let tool = try #require(pack.metadata.tools?.first { $0.id == "inspect-port" })
        let toolOut = try await runtime.runTool(tool, in: pack, query: "59999").get()
        #expect(toolOut.contains("59999"))
    }

    // MARK: - Step 3: Permission-Gated $DORAX_CONTEXT, Keychain Secrets & dorax.* Sources

    @Test("DoraxContextBridge strictly gates clipboard and URL fields on declared permissions")
    func contextBridgePermissionGating() {
        let restricted = DoraxPackMetadata(id: "restricted", name: "Restricted", permissions: ["context:frontmost"])
        let permissive = DoraxPackMetadata(
            id: "permissive", name: "Permissive",
            permissions: ["context:frontmost", "context:url", "context:clipboard"])

        let front = DoraxContextPayload.FrontmostInfo(
            appName: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "Video", url: "https://youtube.com/watch?v=1", domain: "youtube.com")
        let clip = DoraxContextPayload.ClipboardInfo(text: "#A486FF", type: "color")

        let rCtx = DoraxContextBridge.buildContext(
            pack: restricted, frontmostOverride: front, clipboardOverride: clip)
        #expect(rCtx.frontmost?.appName == "Safari")
        #expect(rCtx.frontmost?.url == nil)
        #expect(rCtx.clipboard == nil)

        let pCtx = DoraxContextBridge.buildContext(
            pack: permissive, frontmostOverride: front, clipboardOverride: clip)
        #expect(pCtx.frontmost?.url == "https://youtube.com/watch?v=1")
        #expect(pCtx.clipboard?.text == "#A486FF")
        #expect(pCtx.clipboard?.type == "color")
    }

    @Test("Keychain secret preferences store, read, and delete safely")
    func secretPreferenceRoundTrip() {
        let pref = DoraxPackPreference(id: "api_key", title: "API Key", type: .secret, required: true)
        let packID = "test-secret-\(UUID().uuidString)"
        #expect(DoraxPackPreferenceStore.value(for: pref, packID: packID) == nil)
        DoraxPackPreferenceStore.setValue("sk-test-12345", for: pref, packID: packID)
        #expect(DoraxPackPreferenceStore.value(for: pref, packID: packID) == "sk-test-12345")
        DoraxPackPreferenceStore.setValue(nil, for: pref, packID: packID)
        #expect(DoraxPackPreferenceStore.value(for: pref, packID: packID) == nil)
    }

    @Test("Built-in dorax.* native sources resolve cleanly without scripts")
    func nativeDataSourcesResolve() {
        for source in ["dorax.clipboard", "dorax.windows", "dorax.frontmost.menus",
                       "dorax.nowPlaying", "dorax.browser.tabs", "dorax.files", "dorax.notifications"] {
            let out = DoraxContextBridge.resolveNativeSource(source, query: "")
            #expect(out.items.count >= 0)
        }
        let winOut = DoraxContextBridge.resolveNativeSource("dorax.windows", query: "left")
        #expect(!winOut.items.isEmpty)
    }

    @Test("Stale-while-revalidate preserves last good output when a refresh fails")
    func staleWhileRevalidatePreservesGoodOutput() async throws {
        let runtime = DoraxPackV3Runtime()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swr-\(UUID().uuidString).doraxpack", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let marker = tmp.appendingPathComponent("fail-flag")
        let script = """
        if [ -f "\(marker.path)" ]; then
          echo "network offline" >&2
          exit 1
        fi
        echo '{"items":[{"id":"1","title":"Cached Row"}]}'
        """
        let cmd = DoraxPackCommand(
            id: "swr-cmd", title: "SWR Test", mode: .list,
            script: script, timeoutSeconds: 5, cacheTTLSeconds: 0)
        let pack = DoraxPackV2(
            metadata: DoraxPackMetadata(id: "swr-pack", name: "SWR Pack", commands: [cmd]),
            agentInstructions: nil, modes: [], skills: [], scripts: [], pageScripts: [], folderURL: tmp)

        let first = await runtime.runCommand(cmd, in: pack, forceRefresh: true)
        #expect(try first.get().items.first?.title == "Cached Row")

        // Trigger failure on refresh — cached output MUST stay available alongside lastError
        try Data("1".utf8).write(to: marker)
        let second = await runtime.runCommand(cmd, in: pack, forceRefresh: true)
        if case .success = second { Issue.record("Expected failure on second run") }
        let state = runtime.state(packID: "swr-pack", commandID: "swr-cmd")
        #expect(state.output?.items.first?.title == "Cached Row")
        #expect(state.lastError?.contains("network offline") == true)
    }

    // MARK: - Step 4: DockAuraEngine & Notch Live Activities

    @Test("DockAuraEngine respects priority, global toggle, and Reduce Motion")
    func dockAuraEngineBehavior() {
        let aura = DockAuraEngine.shared
        aura.clearAll()
        let prevEnabled = aura.isEnabled
        defer { aura.clearAll(); aura.isEnabled = prevEnabled }

        aura.isEnabled = true
        aura.activate(id: "low", appearance: DoraxPackAppearance(tint: "#38BDF8", glow: .soft), priority: 10)
        aura.activate(id: "high", appearance: DoraxPackAppearance(tint: "#EF4444", glow: .pulse), priority: 90)
        #expect(aura.activeSource?.id == "high")
        #expect(aura.effectiveGlow(reduceMotion: false) == .pulse)
        #expect(aura.effectiveGlow(reduceMotion: true) == .soft)

        aura.isEnabled = false
        #expect(aura.activeSource == nil)
        #expect(aura.effectiveGlow(reduceMotion: false) == .none)
        #expect(DockAuraEngine.color(fromHex: "#38BDF8") != nil)
        #expect(DockAuraEngine.color(fromHex: "not-hex") == nil)
    }

    @Test("DynamicNotchState publishes and dismisses v3 pack live activities cleanly")
    func notchPackLiveActivityLifecycle() {
        let notch = DynamicNotchState.shared
        notch.dismissPackActivity()
        let basePages = notch.pageCount
        notch.publishPackActivity(DoraxNotchLiveActivity(
            packID: "demo",
            packName: "Demo",
            payload: DoraxNotchPayload(wingText: "⎇ 2 PRs", wingIcon: "arrow.triangle.branch", wingColorHex: "#818CF8", title: "Open PRs")))
        #expect(notch.activePackActivity?.payload.wingText == "⎇ 2 PRs")
        #expect(notch.pageCount == basePages + 1)
        notch.dismissPackActivity()
        #expect(notch.activePackActivity == nil)
        #expect(notch.pageCount == basePages)
    }

    // MARK: - Step 5: Scope Ranking (App + Web-App Domains), Hooks (3 Guardrails) & Strict Argv CLI

    @Test("Web-App domain scope matches subdomains, rejects spoofs, and ranks Contextual first")
    func webAppDomainScopeRanking() {
        let ytScope = DoraxPackScope(surfaces: ["global", "notch"], apps: [], domains: ["youtube.com", "youtu.be"])
        #expect(ytScope.matchesDomain("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(ytScope.matchesDomain("https://music.youtube.com/"))
        #expect(ytScope.matchesDomain("https://youtu.be/abc"))
        #expect(!ytScope.matchesDomain("https://notyoutube.com/watch"))

        let tmp = FileManager.default.temporaryDirectory
        let ytCmd = DoraxPackCommand(
            id: "summarize-video", title: "Summarize Video", icon: "play.rectangle",
            mode: .ai, keywords: ["youtube", "video", "tldr"])
        let ytPack = DoraxPackV2(
            metadata: DoraxPackMetadata(
                schemaVersion: 3, id: "youtube-pack", name: "YouTube",
                scope: ytScope, commands: [ytCmd]),
            agentInstructions: "Summarize videos concisely.",
            modes: [], skills: [], scripts: [], pageScripts: [], folderURL: tmp)

        let cfgURL = tmp.appendingPathComponent("v3-cfg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cfgURL) }
        let registry = DoraxPackV3Registry(roots: [tmp.appendingPathComponent("empty-\(UUID().uuidString)")], configFileURL: cfgURL)
        registry.register(ytPack)

        // When YouTube URL is active in Safari, ranks under Contextual — YouTube
        let ctx = registry.contextualCommands(
            frontmostBundleID: "com.apple.Safari",
            frontmostURL: "https://www.youtube.com/watch?v=123",
            query: "")
        #expect(ctx.count == 1)
        #expect(ctx[0].sectionTitle == "Contextual — YouTube")

        // User alias search works from background
        registry.updateCommandConfig(packID: "youtube-pack", commandID: "summarize-video") { $0.alias = "yt" }
        let bg = registry.globalSearchCommands(query: "yt")
        #expect(bg.first?.command.id == "summarize-video")

        // @pack mention resolution works
        let mentions = registry.resolveMentions(in: "Use @youtube-pack.summarize-video on this tab")
        #expect(mentions.count == 1)
        #expect(mentions[0].command?.id == "summarize-video")
    }

    @Test("Hook dispatcher enforces all 3 guardrails: Swift pre-filter, consent + circuit breaker, suggest-only output")
    func hookDispatcherThreeGuardrails() async {
        let tmp = FileManager.default.temporaryDirectory
        let cfgURL = tmp.appendingPathComponent("hook-cfg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cfgURL) }
        let registry = DoraxPackV3Registry(roots: [tmp.appendingPathComponent("empty-\(UUID().uuidString)")], configFileURL: cfgURL)
        let runtime = DoraxPackV3Runtime()

        // Guardrail 1: empty filter rejected by validator AND matcher
        let emptyHook = DoraxPackHook(id: "bad-hook", on: .clipboard, script: "hooks/x.py", filter: DoraxPackHookFilter())
        #expect(!DoraxPackHookDispatcher.matchesFilter(emptyHook.filter, event: DoraxHookEvent(kind: .clipboard, clipboardText: "hi", clipboardType: "text")))
        let badPack = DoraxPackV2(
            metadata: DoraxPackMetadata(id: "bad", name: "Bad", hooks: [emptyHook]),
            agentInstructions: nil, modes: [], skills: [], scripts: [], pageScripts: [], folderURL: tmp)
        #expect(DoraxPackV3Validator.validate(badPack).contains(where: { $0.severity == .error }))

        // Valid color clipboard hook
        let colorHook = DoraxPackHook(
            id: "hex-color",
            on: .clipboard,
            script: "hooks/color.py",
            filter: DoraxPackHookFilter(types: ["color"], regex: "^#[0-9A-Fa-f]{6}$"))
        let colorPack = DoraxPackV2(
            metadata: DoraxPackMetadata(
                schemaVersion: 3, id: "color-pack", name: "Color Pack",
                permissions: ["hook:clipboard"], hooks: [colorHook]),
            agentInstructions: nil, modes: [], skills: [], scripts: [], pageScripts: [], folderURL: tmp)
        registry.register(colorPack)

        let dispatcher = DoraxPackHookDispatcher(registry: registry, runtime: runtime)
        var shouldFail = false
        dispatcher.processExecutor = { _, _, _, _ in
            if shouldFail {
                return .failure(PluginRunFailure(message: "simulated crash", kind: .exit))
            }
            return .success(PluginRunResult(
                stdout: ##"{"suggestions":[{"title":"Copy as SwiftUI Color","subtitle":"#A486FF","icon":"paintpalette"}],"state":{"last":"#A486FF"}}"##,
                stderr: "", exitCode: 0))
        }

        // Guardrail 2 (consent): without granted hook:clipboard, spawns 0 processes
        let matchEvent = DoraxHookEvent(kind: .clipboard, clipboardText: "#A486FF", clipboardType: "color")
        await dispatcher.dispatchImmediatelyForTesting(matchEvent)
        #expect(dispatcher.spawnedProcessCount == 0)

        // Grant consent
        var cfg = registry.packConfig(for: "color-pack")
        cfg.grantedPermissions.insert("hook:clipboard")
        registry.setPackConfig(cfg, for: "color-pack")

        // Guardrail 1 (Swift pre-filter): unmatched clipboard text spawns 0 processes!
        let unmatchedEvent = DoraxHookEvent(kind: .clipboard, clipboardText: "plain sentence", clipboardType: "text")
        await dispatcher.dispatchImmediatelyForTesting(unmatchedEvent)
        #expect(dispatcher.spawnedProcessCount == 0)

        // Matched event fires & stages suggestion (Guardrail 3)
        await dispatcher.dispatchImmediatelyForTesting(matchEvent)
        #expect(dispatcher.spawnedProcessCount == 1)
        #expect(dispatcher.stagedSuggestions.first?.title == "Copy as SwiftUI Color")
        #expect(dispatcher.lastHookState["color-pack"]?["last"] == "#A486FF")

        // Guardrail 2 (Circuit Breaker): 3 consecutive crashes auto-disable the hook
        shouldFail = true
        await dispatcher.dispatchImmediatelyForTesting(matchEvent)
        await dispatcher.dispatchImmediatelyForTesting(matchEvent)
        await dispatcher.dispatchImmediatelyForTesting(matchEvent)
        let key = DoraxPackHookDispatcher.HookKey(packID: "color-pack", hookID: "hex-color")
        #expect(dispatcher.disabledHooks[key] != nil)
        let countAfterTrip = dispatcher.spawnedProcessCount
        await dispatcher.dispatchImmediatelyForTesting(matchEvent)
        #expect(dispatcher.spawnedProcessCount == countAfterTrip)
    }

    @Test("mode: cli runs strictly as argv without shell interpolation")
    func cliModeRunsStrictArgv() async throws {
        let runtime = DoraxPackV3Runtime()
        let cmd = DoraxPackCommand(
            id: "echo-argv", title: "Echo Argv", mode: .cli,
            binary: "/bin/echo", args: ["literal-$HOME-test"])
        let pack = DoraxPackV2(
            metadata: DoraxPackMetadata(id: "cli-test", name: "CLI Test", commands: [cmd]),
            agentInstructions: nil, modes: [], skills: [], scripts: [], pageScripts: [],
            folderURL: FileManager.default.temporaryDirectory)

        let out = try await runtime.runCommand(cmd, in: pack, forceRefresh: true).get()
        // Must contain literal `$HOME`, proving no shell expanded it!
        #expect(out.detail?.markdown.contains("literal-$HOME-test") == true)
    }

    // MARK: - Step 6: Context-Aware AI Studio v3 Builder & One-Click Install

    @Test("DoraxPackV3Builder synthesizes a valid Web-App v3 pack, runs dry run, and installs cleanly")
    func studioV3BuilderEndToEnd() async throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("v3-builder-stage-\(UUID().uuidString)", isDirectory: true)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("v3-builder-dest-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: dest)
        }

        let synthesis = await DoraxPackV3Builder.buildForTarget(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            activeURL: "https://github.com/org/repo",
            template: nil,
            stagingRoot: staging)

        #expect(!synthesis.review.hasBlockingErrors)
        #expect(synthesis.review.domains == ["github.com"])
        #expect(synthesis.review.contextFieldsRead.contains("context:url"))
        #expect(!synthesis.review.hookSummaries.isEmpty)
        #expect(synthesis.review.dryRunOutput != nil)

        let installed = try DoraxPackV3Builder.approveAndInstall(
            synthesis, destinationRoot: dest, persistToDisk: false)
        #expect(installed.metadata.isV3)
        #expect(FileManager.default.fileExists(atPath: installed.folderURL.appendingPathComponent("pack.json").path))
        #expect(FileManager.default.fileExists(atPath: installed.folderURL.appendingPathComponent("AGENT.md").path))
    }

    @Test("Schedule hooks parse intervals and evaluate 5-field cron expressions accurately")
    func scheduleHookIntervalAndCronMatching() throws {
        #expect(DoraxPackHookDispatcher.parseEveryInterval("30s") == 30)
        #expect(DoraxPackHookDispatcher.parseEveryInterval("5m") == 300)
        #expect(DoraxPackHookDispatcher.parseEveryInterval("2h") == 7_200)
        #expect(DoraxPackHookDispatcher.parseEveryInterval("1d") == 86_400)
        #expect(DoraxPackHookDispatcher.parseEveryInterval("2s") == 10) // enforced 10s floor
        #expect(DoraxPackHookDispatcher.parseEveryInterval("bad") == nil)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        // 2026-11-26 is a Thursday (weekday 5, cron dow 4)
        let thu0900 = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9, minute: 0)))
        let thu0901 = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9, minute: 1)))
        // 2026-11-29 is a Sunday (weekday 1, cron dow 0 or 7)
        let sun0900 = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 29, hour: 9, minute: 0)))

        #expect(DoraxPackHookDispatcher.matchesCron("0 9 * * 1-5", date: thu0900, calendar: cal))
        #expect(!DoraxPackHookDispatcher.matchesCron("0 9 * * 1-5", date: thu0901, calendar: cal))
        #expect(!DoraxPackHookDispatcher.matchesCron("0 9 * * 1-5", date: sun0900, calendar: cal))
        #expect(DoraxPackHookDispatcher.matchesCron("0 9 * * 7", date: sun0900, calendar: cal))
        #expect(DoraxPackHookDispatcher.matchesCron("*/15 * * * *", date: thu0900, calendar: cal))
    }

    @Test("LegacyPluginCleanup archives and removes legacy currency state & v2 pack and installV2 skips store-packs")
    func legacyCleanupCoversCurrencyStateAndV2Pack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorax-legacy-currency-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }

        let stateCurrency = root.appendingPathComponent("plugins/state/currency.json")
        let v2Currency = root.appendingPathComponent("plugins/v2/currency.doraxpack")
        try fm.createDirectory(at: stateCurrency.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: v2Currency, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: stateCurrency)
        try Data("{}".utf8).write(to: v2Currency.appendingPathComponent("pack.json"))

        let report = LegacyPluginCleanup.runBackupAndCleanup(appSupportRoot: root)
        #expect(report.succeeded)
        #expect(report.removedRelativePaths.contains("plugins/state/currency.json"))
        #expect(report.removedRelativePaths.contains("plugins/v2/currency.doraxpack"))
        #expect(!fm.fileExists(atPath: stateCurrency.path))
        #expect(!fm.fileExists(atPath: v2Currency.path))

        let packsDir = try #require(FirstPartyPacks.resolvePacksDirectory())
        let finderURL = packsDir.appendingPathComponent("Finder.doraxpack", isDirectory: true)
        let finderPack = try DoraxPackV2Loader.load(from: finderURL)
        let bind = try StorePackInstaller.installV2(finderPack, persistToDisk: false)
        #expect(bind.packID == "finder")
    }

    @Test("DoraxHotkeyShortcut parses symbolic & word modifiers, rejects bare keys, and resolves configured v3 command hotkeys")
    func commandHotkeyParsingAndResolution() throws {
        let sym = try #require(DoraxHotkeyShortcut.parse("⌥⇧P"))
        #expect(sym.keyEquivalent == "p")
        #expect(sym.modifiers == [.option, .shift])
        #expect(sym.matches(charactersIgnoringModifiers: "P", modifierFlags: [.option, .shift]))
        #expect(!sym.matches(charactersIgnoringModifiers: "P", modifierFlags: [.option]))

        let words = try #require(DoraxHotkeyShortcut.parse("cmd+opt+k"))
        #expect(words.keyEquivalent == "k")
        #expect(words.modifiers == [.command, .option])

        // Bare single key or shift-only key MUST be rejected so normal typing is never hijacked
        #expect(DoraxHotkeyShortcut.parse("p") == nil)
        #expect(DoraxHotkeyShortcut.parse("⇧P") == nil)

        let tmp = FileManager.default.temporaryDirectory
        let cfgURL = tmp.appendingPathComponent("hk-cfg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cfgURL) }
        let registry = DoraxPackV3Registry(roots: [tmp.appendingPathComponent("empty-\(UUID().uuidString)")], configFileURL: cfgURL)
        let cmd = DoraxPackCommand(id: "ports", title: "Listening Ports", mode: .list)
        let pack = DoraxPackV2(
            metadata: DoraxPackMetadata(schemaVersion: 3, id: "pm-hk", name: "PM", commands: [cmd]),
            agentInstructions: nil, modes: [], skills: [], scripts: [], pageScripts: [], folderURL: tmp)
        registry.register(pack)
        registry.updateCommandConfig(packID: "pm-hk", commandID: "ports") { $0.hotkey = "⌥⇧P" }

        let resolved = registry.matchingCommand(charactersIgnoringModifiers: "p", modifierFlags: [.option, .shift])
        #expect(resolved?.command.id == "ports")
        #expect(registry.matchingCommand(charactersIgnoringModifiers: "p", modifierFlags: [.command]) == nil)
    }

    @Test("Notification hook pre-filter matches senderApps + contains accurately")
    func notificationSenderAppsHookFilter() {
        let filter = DoraxPackHookFilter(senderApps: ["com.apple.mail"], contains: "VIP")
        let matching = DoraxHookEvent(
            kind: .notification,
            notificationSenderBundleID: "com.apple.mail",
            notificationBody: "VIP: Quarterly board deck")
        let wrongSender = DoraxHookEvent(
            kind: .notification,
            notificationSenderBundleID: "com.tinyspeck.slackmacgap",
            notificationBody: "VIP: Quarterly board deck")
        #expect(DoraxPackHookDispatcher.matchesFilter(filter, event: matching))
        #expect(!DoraxPackHookDispatcher.matchesFilter(filter, event: wrongSender))
    }

    // MARK: - Curated 13 Packs, Apple Intelligence, AI Upgrader & Raycast Importer

    @Test("All 19 shipped .doraxpack v3 packs (including 13 curated extensions + corrected Antigravity) validate with 0 errors")
    func curatedPacksLoadAndValidateCleanly() throws {
        let packsDir = try #require(FirstPartyPacks.resolvePacksDirectory())
        let packURLs = DoraxPackV2Loader.discoverPacks(in: packsDir)
        let loaded = try packURLs.map { try DoraxPackV2Loader.load(from: $0) }
        let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })

        let expectedNewIDs = [
            "youtube", "github", "homebrew", "spotify", "obsidian", "tailscale",
            "whatsapp", "claude", "chatgpt", "messages", "notes", "google-drive",
            "apple-intelligence", "antigravity",
            "system-utilities", "currency-converter", "focus-shortcuts", "wallpapers"
        ]
        for id in expectedNewIDs {
            let pack = try #require(byID[id], "Missing curated pack \(id)")
            #expect(pack.metadata.schemaVersion == 3)
            #expect(pack.agentInstructions?.isEmpty == false, "\(id) missing AGENT.md")
            #expect(!pack.skills.isEmpty, "\(id) missing skills")
            #expect(!(pack.metadata.commands ?? []).isEmpty, "\(id) missing commands")
            let errors = DoraxPackV3Validator.validate(pack).filter { $0.severity == .error }
            #expect(errors.isEmpty, "\(id) validation errors: \(errors.map(\.message))")
        }

        let agy = try #require(byID["antigravity"])
        #expect(agy.metadata.bundleId == "com.google.antigravity")
        #expect(agy.metadata.effectiveScope.matchesBundleID("com.google.antigravity"))
    }

    @Test("Contextual ranking matches newly curated native apps and web domains cleanly")
    func contextualRankingNewNativeAndWebApps() throws {
        let packsDir = try #require(FirstPartyPacks.resolvePacksDirectory())
        let cfgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx-curated-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cfgURL) }
        let registry = DoraxPackV3Registry(roots: [packsDir], configFileURL: cfgURL)

        let nativePairs: [(bundle: String, packID: String)] = [
            ("com.spotify.client", "spotify"),
            ("md.obsidian", "obsidian"),
            ("com.google.antigravity", "antigravity"),
            ("net.whatsapp.WhatsApp", "whatsapp"),
            ("com.anthropic.claudefordesktop", "claude"),
            ("com.openai.codex", "chatgpt"),
            ("com.apple.Notes", "notes"),
            ("com.apple.MobileSMS", "messages"),
            ("com.google.drivefs", "google-drive"),
            ("io.tailscale.ipn.macsys", "tailscale"),
        ]
        for (bundle, packID) in nativePairs {
            let matches = registry.contextualCommands(frontmostBundleID: bundle, frontmostURL: nil, query: "")
            #expect(matches.contains(where: { $0.pack.id == packID && $0.isContextual }),
                    "Expected contextual match for \(bundle) -> \(packID)")
        }

        let webPairs: [(url: String, packID: String)] = [
            ("https://www.youtube.com/watch?v=abc", "youtube"),
            ("https://github.com/owner/repo/pulls", "github"),
            ("https://claude.ai/chat/123", "claude"),
            ("https://chatgpt.com/c/123", "chatgpt"),
            ("https://drive.google.com/drive/my-drive", "google-drive"),
        ]
        for (url, packID) in webPairs {
            let matches = registry.contextualCommands(frontmostBundleID: "com.apple.Safari", frontmostURL: url, query: "")
            #expect(matches.contains(where: { $0.pack.id == packID && $0.isContextual }),
                    "Expected web contextual match for \(url) -> \(packID)")
        }
    }

    @Test("Apple Intelligence native commands execute cleanly via DoraxPackV3Runtime in test mode")
    func appleIntelligenceCommandsRunCleanly() async throws {
        let packsDir = try #require(FirstPartyPacks.resolvePacksDirectory())
        let pack = try DoraxPackV2Loader.load(from: packsDir.appendingPathComponent("AppleIntelligence.doraxpack", isDirectory: true))
        let runtime = DoraxPackV3Runtime()

        let proofread = try #require(pack.metadata.commands?.first { $0.id == "proofread" })
        let out = try await runtime.runCommand(
            proofread, in: pack, query: "Helo wrld this is a tset", forceRefresh: true).get()
        #expect(out.detail?.markdown.contains("Proofread") == true)
        #expect(out.items.first?.actions.contains(where: { $0.kind == "copy" }) == true)

        let formCmd = try #require(pack.metadata.commands?.first { $0.id == "writing-tools" })
        let formOut = try await runtime.runCommand(
            formCmd, in: pack, formValues: ["action": "Make Concise", "text": "Long sample text"], forceRefresh: true).get()
        #expect(formOut.detail?.markdown.contains("Make Concise") == true)
    }

    @Test("ExtensionHeaderBarState resets only when ID matches and live selection takes priority over clipboard")
    func extensionHeaderAndSelectionPriority() {
        let state = ExtensionHeaderBarState.shared
        state.update(id: "first", title: "First", icon: "star")
        state.update(id: "second", title: "Second", icon: "bolt", filterOptions: ["All", "Formula"], selectedFilter: "Formula")
        // Resetting stale ID must not clobber newer active header
        state.reset(ifMatching: "first")
        #expect(state.activeID == "second")
        #expect(state.filterOptions == ["All", "Formula"])
        state.reset(ifMatching: "second")
        #expect(state.activeID.isEmpty)

        // Selection priority must beat clipboard when selection text is present
        let spec = DoraxAppleIntelligenceRunner.spec(for: "dorax.appleIntelligence.summarize")
        let pickedSel = DoraxAppleIntelligenceRunner.resolveInputText(
            spec: spec, query: "", formValues: nil,
            selectionOverride: "Highlighted paragraph", clipboardOverride: "Old clipboard item")
        #expect(pickedSel.text == "Highlighted paragraph")
        #expect(pickedSel.sourceLabel == "Selection")

        let fallbackClip = DoraxAppleIntelligenceRunner.resolveInputText(
            spec: spec, query: "", formValues: nil,
            selectionOverride: "", clipboardOverride: "Copied article text")
        #expect(fallbackClip.text == "Copied article text")
        #expect(fallbackClip.sourceLabel == "Clipboard")
    }

    @Test("Phase 1: DoraxPackV3EditorService copy-on-write upgrades, creates backups, rejects invalid patches, rolls back, and resets")
    func editorServiceCopyOnWriteAndRollback() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorax-editor-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let packsDir = tmp.appendingPathComponent("ShippedPacks", isDirectory: true)
        let v3Root = tmp.appendingPathComponent("UserV3", isDirectory: true)
        let backupRoot = tmp.appendingPathComponent("Backups", isDirectory: true)
        let stagingRoot = tmp.appendingPathComponent("Staging", isDirectory: true)

        let shippedDir = packsDir.appendingPathComponent("Demo.doraxpack", isDirectory: true)
        try FileManager.default.createDirectory(at: shippedDir.appendingPathComponent("skills/s"), withIntermediateDirectories: true)
        let baseMeta = DoraxPackMetadata(
            formatVersion: 2, schemaVersion: 3, id: "demo", name: "Demo", version: "3.0.0",
            capabilities: [PluginPackCapability(id: "demo.hi", name: "Hi", intent: "Hi", triggers: ["hi"], type: "aiPrompt", script: "hi", safety: "read")],
            scope: DoraxPackScope(surfaces: ["global"], apps: [], domains: []),
            commands: [DoraxPackCommand(id: "base-cmd", title: "Base Cmd", mode: .list, source: "dorax.windows")])
        try Data(DoraxPackV3AIArchitect.encodeMetadata(baseMeta).utf8).write(to: shippedDir.appendingPathComponent("pack.json"))
        try Data("# Demo\n".utf8).write(to: shippedDir.appendingPathComponent("AGENT.md"))
        try Data("# Skill\n".utf8).write(to: shippedDir.appendingPathComponent("skills/s/SKILL.md"))

        let cfgURL = tmp.appendingPathComponent("cfg.json")
        let registry = DoraxPackV3Registry(roots: [packsDir, v3Root], configFileURL: cfgURL)
        let editor = DoraxPackV3EditorService()
        let basePack = try #require(registry.pack(id: "demo"))

        // Propose AI upgrade in offline mode
        let patch = await DoraxPackV3AIArchitect.proposeUpgrade(
            pack: basePack, instruction: "Add release notes checker", stagingRoot: stagingRoot, useLiveAI: false)
        #expect(!patch.hasBlockingErrors)
        #expect(!patch.files.isEmpty)

        // Apply upgrade via Copy-on-Write
        let upgraded = try editor.applyPatch(
            patch, to: basePack, v3Root: v3Root, backupRoot: backupRoot, registry: registry, persistToDisk: false)
        #expect(upgraded.metadata.commands?.count == 2)
        #expect(upgraded.metadata.commands?.contains(where: { $0.id == "base-cmd" }) == true)
        #expect(editor.isUserOverride(packID: "demo", v3Root: v3Root))
        #expect(editor.listBackups(for: "demo", backupRoot: backupRoot).count == 1)

        // Invalid path traversal must be rejected without corrupting pack
        let badPatch = DoraxPackV3Patch(
            packID: "demo", packName: "Demo", summary: "Bad",
            updatedPackJSON: patch.updatedPackJSON,
            files: [DoraxPackV3FileChange(relativePath: "../escape.py", content: "bad", isNew: true)],
            addedPermissions: [], addedHooks: [], diagnostics: [],
            dryRunOutput: nil, dryRunError: nil, stagedFolderURL: patch.stagedFolderURL)
        #expect(throws: DoraxPackEditorError.self) {
            try editor.applyPatch(badPatch, to: upgraded, v3Root: v3Root, backupRoot: backupRoot, registry: registry, persistToDisk: false)
        }

        // Rollback restores original 1-command state
        let rolledBack = try editor.rollback(
            packID: "demo", v3Root: v3Root, backupRoot: backupRoot, registry: registry, persistToDisk: false)
        #expect(rolledBack.metadata.commands?.count == 1)

        // Reset removes user override completely
        let reset = try editor.resetToDefault(
            packID: "demo", v3Root: v3Root, packsDirectory: packsDir, registry: registry, persistToDisk: false)
        #expect(reset?.metadata.version == "3.0.0")
        #expect(!editor.isUserOverride(packID: "demo", v3Root: v3Root))
    }

    @Test("Phase 2: RaycastImporter converts Script Commands and local Raycast package.json extensions (standalone & merge)")
    func raycastScriptAndExtensionImport() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorax-raycast-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // 1. Raycast Script Command
        let scriptFile = tmp.appendingPathComponent("hello-raycast.sh")
        let scriptContent = """
        #!/bin/bash
        # @raycast.schemaVersion 1
        # @raycast.title Flush DNS Cache
        # @raycast.mode inline
        # @raycast.packageName Network Utils
        # @raycast.refreshTime 5m
        # @raycast.argument1 { "type": "text", "placeholder": "Host", "optional": true }
        echo "OK $1"
        """
        try Data(scriptContent.utf8).write(to: scriptFile)

        let parsed = try #require(RaycastImporter.parseScriptMetadata(content: scriptContent))
        #expect(parsed.title == "Flush DNS Cache")
        #expect(parsed.mode == "inline")
        #expect(parsed.arguments.count == 1)
        #expect(RaycastImporter.parseRefreshSeconds(parsed.refreshTime) == 300)

        let scriptImport = try await RaycastImporter.importScriptCommand(
            fileURL: scriptFile,
            stagingRoot: tmp.appendingPathComponent("stage1"))
        let syn = try #require(scriptImport.synthesis)
        #expect(!scriptImport.hasBlockingErrors)
        #expect(syn.pack.metadata.commands?.first?.mode == .form)
        #expect(syn.pack.metadata.commands?.first?.refreshSeconds == 300)

        // Merge same script into existing pack
        let targetPack = syn.pack
        let mergeImport = try await RaycastImporter.importScriptCommand(
            fileURL: scriptFile,
            mergeIntoPack: targetPack,
            stagingRoot: tmp.appendingPathComponent("stage-merge"))
        #expect(mergeImport.patch != nil)
        #expect(!mergeImport.hasBlockingErrors)

        // 2. Raycast local extension package.json
        let extDir = tmp.appendingPathComponent("my-raycast-ext", isDirectory: true)
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let pkgJSON = """
        {
          "name": "sample-ext",
          "title": "Sample Extension",
          "description": "Two sample Raycast commands.",
          "commands": [
            {"name": "search-items", "title": "Search Items", "description": "Find items", "mode": "view"},
            {"name": "quick-ping", "title": "Quick Ping", "description": "Ping quietly", "mode": "no-view"}
          ],
          "preferences": [
            {"name": "apiToken", "title": "API Token", "type": "password", "required": true}
          ]
        }
        """
        try Data(pkgJSON.utf8).write(to: extDir.appendingPathComponent("package.json"))
        let extImport = try await RaycastImporter.importExtension(
            from: extDir.path,
            stagingRoot: tmp.appendingPathComponent("stage-ext"),
            useLiveAI: false)
        let extSyn = try #require(extImport.synthesis)
        #expect(!extImport.hasBlockingErrors)
        #expect(extSyn.pack.metadata.commands?.count == 2)
        #expect(extSyn.pack.metadata.preferences?.first?.type == .secret)
    }

    @Test("Wallpapers schema extensions: directory/file prefs, thumbnail_path, image_path, and next-wallpaper retirement")
    func wallpapersSchemaAndLegacyRetirement() throws {
        let json = """
        {
          "items": [
            {
              "id": "w1",
              "title": "Sample.jpg",
              "thumbnail_path": "/tmp/sample.jpg",
              "actions": [
                {"id": "pick", "title": "Choose Folder", "kind": "pick_folder", "value": "folder"}
              ]
            }
          ],
          "detail": {
            "markdown": "### Sample.jpg",
            "image_path": "/tmp/sample.jpg"
          }
        }
        """
        let output = DoraxCommandOutput.parse(stdout: json, commandTitle: "Wallpapers")
        #expect(output.items.first?.thumbnailPath == "/tmp/sample.jpg")
        #expect(output.detail?.imagePath == "/tmp/sample.jpg")
        #expect(output.items.first?.actions.first?.kind == "pick_folder")

        let dirPref = try JSONDecoder().decode(
            DoraxPackPreference.self,
            from: Data(#"{"id":"folder","title":"Wallpaper Folder","type":"directory"}"#.utf8))
        #expect(dirPref.type == .directory)
        let filePref = try JSONDecoder().decode(
            DoraxPackPreference.self,
            from: Data(#"{"id":"pic","title":"Picture","type":"file"}"#.utf8))
        #expect(filePref.type == .file)

        // Legacy essentials next-wallpaper plugin must be listed for safe zip backup & retirement
        #expect(LegacyPluginCleanup.legacyRelativePaths.contains("plugins/essentials/plugins/next-wallpaper"))
    }

    @Test("RaycastImporter avoids pack ID collisions, detects installed apps, and Safari pack ships all 9 commands")
    func raycastImporterCollisionSafetyAndSafariPack() async throws {
        let packsDir = try #require(FirstPartyPacks.resolvePacksDirectory())
        let safariURL = packsDir.appendingPathComponent("Safari.doraxpack", isDirectory: true)
        let safariPack = try DoraxPackV2Loader.load(from: safariURL)
        #expect(safariPack.metadata.bundleId == "com.apple.Safari")
        #expect(safariPack.metadata.effectiveScope.matchesBundleID("com.apple.Safari"))
        let cmdIDs = Set((safariPack.metadata.commands ?? []).map(\.id))
        #expect(cmdIDs.count == 9)
        for expected in ["search-tabs", "search-bookmarks", "reading-list", "search-history", "search-all", "add-to-reading-list", "copy-tab-url", "copy-tab-markdown", "open-tabs"] {
            #expect(cmdIDs.contains(expected), "Missing Safari command \(expected)")
        }
        let errors = DoraxPackV3Validator.validate(safariPack).filter { $0.severity == .error }
        #expect(errors.isEmpty, "Safari pack validation errors: \(errors.map(\.message))")

        // Installed app detection finds Safari -> com.apple.Safari
        let detected = RaycastImporter.detectInstalledApp(matchingSlug: "safari", title: "Safari")
        #expect(detected?.bundleID == "com.apple.Safari")

        // Suggested merge matches existing Safari pack for raycast.com/loris/safari
        let suggested = RaycastImporter.suggestedMergePackID(
            for: "https://www.raycast.com/loris/safari",
            existingPacks: [safariPack])
        #expect(suggested == "safari")

        // Standalone import with colliding existingPackIDs namespaces ID to raycast-safari
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorax-raycast-col-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let imported = try await RaycastImporter.importExtension(
            from: "https://www.raycast.com/loris/safari",
            mergeIntoPack: nil,
            existingPackIDs: ["safari"],
            stagingRoot: tmp,
            useLiveAI: false)
        let syn = try #require(imported.synthesis)
        #expect(syn.pack.id == "raycast-safari")
        #expect(imported.matchedAppBundleID == "com.apple.Safari")
        #expect(syn.pack.metadata.effectiveScope.matchesBundleID("com.apple.Safari"))

        // Precedence test: legacy v2 must not shadow newer firstParty, while v3 overrides cleanly
        let v2Root = tmp.appendingPathComponent("v2", isDirectory: true)
        let v3Root = tmp.appendingPathComponent("v3", isDirectory: true)
        let fpRoot = tmp.appendingPathComponent("fp", isDirectory: true)
        for (dir, ver) in [(v2Root, "2.0.0"), (fpRoot, "3.1.0")] {
            let p = dir.appendingPathComponent("Safari.doraxpack", isDirectory: true)
            try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
            let meta = DoraxPackMetadata(formatVersion: 2, schemaVersion: 3, id: "safari", name: "Safari", version: ver)
            try Data(DoraxPackV3AIArchitect.encodeMetadata(meta).utf8).write(to: p.appendingPathComponent("pack.json"))
        }
        let cfgURL = tmp.appendingPathComponent("cfg.json")
        let precReg = DoraxPackV3Registry(roots: [v2Root, fpRoot, v3Root], configFileURL: cfgURL)
        #expect(precReg.pack(id: "safari")?.metadata.version == "3.1.0")
    }

    @Test("DoraxItemAction decodes Raycast/AI aliases (type/path/target/confirm/payload), icon_path, and run drill-down")
    func itemActionAliasesIconPathAndRunDrillDown() async throws {
        let json = """
        {
          "items": [
            {
              "id": "/Applications/Demo.app",
              "title": "Demo",
              "icon_path": "/Applications/Demo.app",
              "actions": [
                {
                  "title": "Show Leftover Files",
                  "type": "run",
                  "payload": {"id": "leftovers", "name": "Demo"}
                },
                {
                  "title": "Move App Only to Trash",
                  "type": "run",
                  "payload": {"id": "app_only", "path": "/Applications/Demo.app"},
                  "confirm": "Move Demo to Trash?"
                },
                {
                  "title": "Reveal in Finder",
                  "type": "reveal",
                  "path": "/Applications/Demo.app"
                },
                {
                  "title": "Open Docs",
                  "type": "open",
                  "target": "https://example.com"
                }
              ]
            }
          ]
        }
        """
        let output = DoraxCommandOutput.parse(stdout: json, commandTitle: "Uninstall")
        let item = try #require(output.items.first)
        #expect(item.iconPath == "/Applications/Demo.app")
        #expect(item.actions.count == 4)

        let showLeftovers = item.actions[0]
        #expect(showLeftovers.kind == "run")
        #expect(showLeftovers.destructive == false)
        #expect(showLeftovers.payloadJSON?.contains("leftovers") == true)

        let trashAct = item.actions[1]
        #expect(trashAct.kind == "run")
        #expect(trashAct.destructive == true)
        #expect(trashAct.confirmMessage == "Move Demo to Trash?")

        #expect(item.actions[2].kind == "reveal")
        #expect(item.actions[2].value == "/Applications/Demo.app")
        #expect(item.actions[3].kind == "open")
        #expect(item.actions[3].value == "https://example.com")

        // Verify `run` action forwards payload in ctx["action"] + DORAX_ACTION and updates command cache cleanly
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorax-run-drill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("commands"), withIntermediateDirectories: true)
        let py = """
        #!/usr/bin/env python3
        import json, os, sys
        ctx = json.loads(sys.stdin.read() or '{}')
        act = ctx.get('action') or {}
        if act.get('id') == 'leftovers':
            print(json.dumps({"items": [{"id": "left1", "title": "Leftover Cache"}], "toast": "Loaded leftovers"}))
        else:
            print(json.dumps({"items": [{"id": "root", "title": "Root App"}]}))
        """
        let scriptURL = tmp.appendingPathComponent("commands/uninstall.py")
        try Data(py.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let cmd = DoraxPackCommand(id: "uninstall", title: "Uninstall App", mode: .list, script: "commands/uninstall.py")
        let pack = DoraxPackV2(
            metadata: DoraxPackMetadata(schemaVersion: 3, id: "mole-test-\(UUID().uuidString.prefix(6))", name: "Mole Test", commands: [cmd]),
            agentInstructions: nil, modes: [], skills: [], scripts: [], pageScripts: [], folderURL: tmp)

        let runtime = DoraxPackV3Runtime()
        let res = await runtime.runItemActionDetailed(showLeftovers, in: pack, command: cmd, item: item)
        let outcome = try res.get()
        #expect(outcome.didReplaceOutput == true)
        #expect(outcome.message == "Loaded leftovers")
        let cached = runtime.state(packID: pack.id, commandID: cmd.id)
        #expect(cached.output?.items.first?.title == "Leftover Cache")
    }

    @Test("Raycast importer maps arguments, dropdown/bool prefs, menu-bar notch, AI tools, ai_prompt output, and explicit scopes")
    func raycastParityAndExplicitScope() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorax-rc-parity-\(UUID().uuidString)", isDirectory: true)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorax-rc-stage-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let pkgJSON = """
        {
          "name": "safari-helper",
          "title": "Safari AI Helper",
          "description": "Manage Safari tabs and summarize with AI",
          "ai": { "instructions": "Always cite active tab URLs concisely." },
          "preferences": [
            { "name": "autoSummary", "title": "Auto Summarize", "type": "checkbox", "default": false, "required": false },
            { "name": "apiKey", "title": "API Key", "type": "password", "required": true }
          ],
          "commands": [
            {
              "name": "ask-tabs",
              "title": "Ask Tabs",
              "mode": "view",
              "arguments": [
                { "name": "topic", "placeholder": "Topic", "type": "text", "required": true },
                { "name": "tone", "placeholder": "Tone", "type": "dropdown", "data": [
                  { "title": "Short", "value": "short" },
                  { "title": "Deep", "value": "deep" }
                ]}
              ],
              "preferences": [
                { "name": "cmdFormat", "title": "Format", "type": "dropdown", "data": [{ "title": "Markdown", "value": "md" }] }
              ]
            },
            {
              "name": "tab-count",
              "title": "Tab Counter",
              "mode": "menu-bar"
            }
          ],
          "tools": [
            { "name": "get-active-tab", "title": "Get Active Tab", "description": "Reads active tab URL" }
          ]
        }
        """
        try Data(pkgJSON.utf8).write(to: tmp.appendingPathComponent("package.json"))

        // 1. Explicit Global Only overrides Safari auto-detection!
        let globalResult = try await RaycastImporter.importExtension(
            from: tmp.path,
            existingPackIDs: [],
            stagingRoot: staging,
            useLiveAI: false,
            scopeMode: .globalOnly)
        let globalMeta = try #require(globalResult.synthesis?.pack.metadata)
        #expect(globalMeta.bundleId == nil)
        #expect(globalMeta.scope?.surfaces.contains("global") == true)
        #expect(globalMeta.scope?.surfaces.contains("notch") == true)
        #expect(globalMeta.scope?.apps.isEmpty != false)
        #expect(globalResult.importedToolCount == 1)
        #expect(globalMeta.tools?.first?.id == "get-active-tab")
        #expect(globalMeta.preferences?.count == 3)
        let autoSummary = globalMeta.preferences?.first { $0.id == "autoSummary" }
        #expect(autoSummary?.type == .boolean)
        #expect(autoSummary?.defaultValue == "false")
        let askCmd = try #require(globalMeta.commands?.first { $0.id == "ask-tabs" })
        #expect(askCmd.mode == .form)
        #expect(askCmd.formFields?.count == 2)
        #expect(askCmd.formFields?[1].type == "select")
        #expect(askCmd.formFields?[1].options == ["short", "deep"])
        let notchCmd = try #require(globalMeta.commands?.first { $0.id == "tab-count" })
        #expect(notchCmd.mode == .notch)
        #expect(globalResult.synthesis?.pack.agentInstructions?.contains("Always cite active tab URLs concisely.") == true)

        // 2. Explicit Frontmost App Only & Website Domain scoping
        let appOnlyResult = try await RaycastImporter.importExtension(
            from: tmp.path,
            existingPackIDs: [],
            stagingRoot: staging,
            useLiveAI: false,
            scopeMode: .frontmostAppOnly,
            targetAppBundleID: "com.apple.Safari")
        let appOnlyMeta = try #require(appOnlyResult.synthesis?.pack.metadata)
        #expect(appOnlyMeta.bundleId == "com.apple.Safari")
        #expect(appOnlyMeta.scope?.surfaces.contains("appPet") == true)
        #expect(appOnlyMeta.scope?.surfaces.contains("global") == false)

        let webResult = try await RaycastImporter.importExtension(
            from: tmp.path,
            existingPackIDs: [],
            stagingRoot: staging,
            useLiveAI: false,
            scopeMode: .webDomain,
            targetDomain: "github.com")
        let webMeta = try #require(webResult.synthesis?.pack.metadata)
        #expect(webMeta.scope?.surfaces.contains("web") == true)
        #expect(webMeta.scope?.domains == ["github.com"])

        // 3. Script-emitted ai_prompt & ai_system decoding on DoraxCommandOutput
        let aiOut = DoraxCommandOutput.parse(
            stdout: #"{"ai_prompt":"Summarize","ai_system":"Be brief","toast":"Asking"}"#,
            commandTitle: "AI")
        #expect(aiOut.aiPrompt == "Summarize")
        #expect(aiOut.aiSystem == "Be brief")
        #expect(aiOut.toast == "Asking")
    }
}

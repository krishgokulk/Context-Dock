// Context-Dock/Services/Plugins/DoraxPackHookDispatcher.swift
// Context-Dock
//
// Reactive Event Hook Dispatcher for `.doraxpack` v3 `hooks/` (Step 5).
//
// Strictly enforces all 3 Mandatory Guardrails:
// 1. Swift Pre-Filter First (<0.05ms): evaluates `apps`, `domains`, `types`, `regex`,
//    `fileExtensions`, `senderApps`, `contains`, `every`, `cron` in Swift before EVER
//    spawning a subprocess. Hooks with an empty filter are unconditionally rejected.
// 2. Consent + Coalescing + Circuit Breaker: requires install-time hook permission
//    (`hook:*`), per-pack `hooksEnabled` toggle, >=250ms debounce coalescing, strict 3s
//    timeout, and auto-disables a hook after 3 consecutive crashes.
// 3. Suggest/Surface Only — Never Silent Destructive Writes: hook JSON output may ONLY
//    update pack state, publish a Notch wing/banner, trigger Dock glow, or stage
//    non-destructive suggestions; destructive actions always require user confirmation.

import AppKit
import Combine
import Foundation

// MARK: - Event Payload

struct DoraxHookEvent: Equatable {
    let kind: DoraxHookEventKind
    var bundleID: String? = nil
    var appName: String? = nil
    var url: String? = nil
    var clipboardText: String? = nil
    var clipboardType: String? = nil // "url" | "color" | "text" | "file"
    var selectedText: String? = nil
    var selectedFilePaths: [String] = []
    var notificationSenderBundleID: String? = nil
    var notificationBody: String? = nil
}

// MARK: - Hook Output (Suggest / Surface Only — Guardrail 3)

struct DoraxHookSuggestion: Codable, Equatable, Identifiable {
    var id: String
    var packID: String?
    var title: String
    var subtitle: String?
    var icon: String
    var action: DoraxItemAction?

    init(
        id: String = UUID().uuidString,
        packID: String? = nil,
        title: String,
        subtitle: String? = nil,
        icon: String = "sparkles",
        action: DoraxItemAction? = nil
    ) {
        self.id = id; self.packID = packID; self.title = title
        self.subtitle = subtitle; self.icon = icon; self.action = action
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        packID = try c.decodeIfPresent(String.self, forKey: .packID)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "sparkles"
        action = try c.decodeIfPresent(DoraxItemAction.self, forKey: .action)
    }
}

struct DoraxHookOutput: Codable, Equatable {
    var notch: DoraxNotchPayload?
    var appearance: DoraxPackAppearance?
    var suggestions: [DoraxHookSuggestion]?
    var state: [String: String]?
}

// MARK: - Dispatcher

@MainActor
final class DoraxPackHookDispatcher: ObservableObject {
    static let shared = DoraxPackHookDispatcher()

    struct HookKey: Hashable {
        let packID: String
        let hookID: String
    }

    /// Guardrail 2 constants
    static let minimumDebounceMs: Int = 250
    static let hookTimeoutSeconds: TimeInterval = 3.0
    static let circuitBreakerFailureLimit: Int = 3

    @Published private(set) var stagedSuggestions: [DoraxHookSuggestion] = []
    @Published private(set) var disabledHooks: [HookKey: String] = [:]
    @Published private(set) var failureCounts: [HookKey: Int] = [:]
    @Published private(set) var lastHookState: [String: [String: String]] = [:]

    /// Observable counter of subprocesses actually spawned (used by tests to prove
    /// Guardrail 1 spawns ZERO processes on unmatched events).
    private(set) var spawnedProcessCount: Int = 0

    private let registry: DoraxPackV3Registry
    private let runtime: DoraxPackV3Runtime
    private let runner = PluginScriptRunner()
    private var debounceTasks: [HookKey: Task<Void, Never>] = [:]
    private var lastScheduleFire: [HookKey: Date] = [:]
    private var isApplyingHookOutput: Bool = false
    private var workspaceObserver: NSObjectProtocol?
    private var browserContextCancellable: AnyCancellable?
    private var lastDispatchedBrowserURL: String?
    private var scheduleTimer: Timer?
    private var isStarted = false

    var isDispatchingInternalOutput: Bool { isApplyingHookOutput }

    /// Test seam: override subprocess execution in unit tests for deterministic crash/output testing.
    var processExecutor: ((DoraxPackV2, DoraxPackHook, DoraxHookEvent, TimeInterval) async -> Result<PluginRunResult, PluginRunFailure>)?

    init(
        registry: DoraxPackV3Registry = .shared,
        runtime: DoraxPackV3Runtime = .shared
    ) {
        self.registry = registry
        self.runtime = runtime
    }

    func startObserving() {
        guard !isStarted, !AppDelegate.isHostingTests else { return }
        isStarted = true

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier, !bid.isEmpty
            else { return }
            let name = app.localizedName ?? bid
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dispatch(DoraxHookEvent(kind: .frontmostChange, bundleID: bid, appName: name))
                if let url = DoraxContextBridge.activeBrowserURL(for: app) {
                    self.lastDispatchedBrowserURL = url
                    self.dispatch(DoraxHookEvent(kind: .urlChange, bundleID: bid, appName: name, url: url))
                }
            }
        }

        // Also observe in-browser tab switches & URL navigations via SafariBrowserBridge!
        browserContextCancellable = SafariBrowserBridge.shared.$latestContext
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ctx in
                guard let self, let rawURL = ctx?.url.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawURL.isEmpty,
                      SensitivePageGuard.allows(rawURL),
                      rawURL != self.lastDispatchedBrowserURL
                else { return }
                self.lastDispatchedBrowserURL = rawURL
                self.dispatch(DoraxHookEvent(
                    kind: .urlChange,
                    bundleID: "com.apple.Safari",
                    appName: "Safari",
                    url: rawURL))
            }

        scheduleTimer?.invalidate()
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateScheduledHooks(now: Date())
            }
        }
    }

    func stopObserving() {
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
        browserContextCancellable?.cancel()
        browserContextCancellable = nil
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        debounceTasks.values.forEach { $0.cancel() }
        debounceTasks.removeAll()
        isStarted = false
    }

    func resetCircuitBreaker(packID: String, hookID: String) {
        let key = HookKey(packID: packID, hookID: hookID)
        failureCounts[key] = 0
        disabledHooks.removeValue(forKey: key)
    }

    // MARK: - Guardrail 1: Pure Swift Pre-Filter (<0.05ms, zero subprocess on mismatch)

    nonisolated static func matchesFilter(_ filter: DoraxPackHookFilter, event: DoraxHookEvent) -> Bool {
        // Mandatory: a hook with no declared filter NEVER runs.
        guard filter.hasAnyFilter else { return false }

        switch event.kind {
        case .frontmostChange:
            guard let apps = filter.apps, !apps.isEmpty,
                  let bid = event.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bid.isEmpty
            else { return false }
            return apps.contains { $0.caseInsensitiveCompare(bid) == .orderedSame }

        case .urlChange:
            guard let domains = filter.domains, !domains.isEmpty,
                  let rawURL = event.url, !rawURL.isEmpty
            else { return false }
            let host = DoraxPackScope.normalizedHost(from: rawURL)
            guard !host.isEmpty else { return false }
            return domains.contains { declared in
                let d = DoraxPackScope.normalizedHost(from: declared)
                return !d.isEmpty && (host == d || host.hasSuffix("." + d))
            }

        case .clipboard:
            if let allowedTypes = filter.types, !allowedTypes.isEmpty {
                let actual = (event.clipboardType ?? "").lowercased()
                guard allowedTypes.contains(where: { $0.lowercased() == actual }) else { return false }
            }
            if let pattern = filter.regex, !pattern.isEmpty {
                guard let text = event.clipboardText, !text.isEmpty,
                      matchesRegex(pattern, in: text)
                else { return false }
            }
            return (filter.types?.isEmpty == false) || (filter.regex?.isEmpty == false)

        case .selection:
            var checked = false
            if let exts = filter.fileExtensions, !exts.isEmpty {
                checked = true
                let normalizedAllowed = Set(exts.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
                let selectedExts = Set(event.selectedFilePaths.map { URL(fileURLWithPath: $0).pathExtension.lowercased() })
                if selectedExts.isDisjoint(with: normalizedAllowed) { return false }
            }
            if let pattern = filter.regex, !pattern.isEmpty {
                checked = true
                guard let text = event.selectedText, !text.isEmpty,
                      matchesRegex(pattern, in: text)
                else { return false }
            }
            return checked

        case .notification:
            var checked = false
            if let senders = filter.senderApps, !senders.isEmpty {
                checked = true
                guard let sender = event.notificationSenderBundleID,
                      senders.contains(where: { $0.caseInsensitiveCompare(sender) == .orderedSame })
                else { return false }
            }
            if let needle = filter.contains, !needle.isEmpty {
                checked = true
                guard let body = event.notificationBody,
                      body.localizedCaseInsensitiveContains(needle)
                else { return false }
            }
            return checked

        case .schedule:
            return !(filter.every?.isEmpty ?? true) || !(filter.cron?.isEmpty ?? true)
        }
    }

    private nonisolated static func matchesRegex(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, range: range) != nil
    }

    // MARK: - Schedule Parsing & Evaluation (`every` / 5-field `cron`)

    /// Parses intervals like `"30s"`, `"5m"`, `"2h"`, `"1d"` (enforcing a 10s floor).
    nonisolated static func parseEveryInterval(_ raw: String) -> TimeInterval? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.count >= 2, let unit = s.last,
              let value = Double(s.dropLast()), value > 0
        else { return nil }
        let multiplier: TimeInterval
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3_600
        case "d": multiplier = 86_400
        default: return nil
        }
        return max(10, value * multiplier)
    }

    /// Evaluates a standard 5-field cron expression (`min hour dom month dow`) against `date`.
    /// Supports `*`, `*/step`, `n`, `a-b`, comma-separated lists, and Sunday as `0` or `7`.
    nonisolated static func matchesCron(
        _ expr: String,
        date: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let fields = expr.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard fields.count == 5 else { return false }

        let comps = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = comps.minute,
              let hour = comps.hour,
              let dom = comps.day,
              let month = comps.month,
              let weekdayOneBased = comps.weekday
        else { return false }

        // Calendar `.weekday` is 1 = Sunday ... 7 = Saturday; cron is 0 or 7 = Sunday, 1 = Monday ... 6 = Saturday.
        let dow = weekdayOneBased - 1

        func matchesField(_ field: String, value: Int, minVal: Int, maxVal: Int, allowSevenAsZero: Bool = false) -> Bool {
            for part in field.split(separator: ",").map(String.init) {
                if part == "*" { return true }
                if part.hasPrefix("*/"), let step = Int(part.dropFirst(2)), step > 0 {
                    if (value - minVal) % step == 0 { return true }
                    continue
                }
                let rangeParts = part.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                if rangeParts.count == 2, let lo = Int(rangeParts[0]), let hi = Int(rangeParts[1]), lo <= hi {
                    let mappedVal = (allowSevenAsZero && value == 0 && hi >= 7) ? 7 : value
                    if (mappedVal >= lo && mappedVal <= hi) || (value >= lo && value <= hi) { return true }
                    continue
                }
                if let exact = Int(part) {
                    if exact == value || (allowSevenAsZero && value == 0 && exact == 7) { return true }
                }
            }
            return false
        }

        return matchesField(fields[0], value: minute, minVal: 0, maxVal: 59)
            && matchesField(fields[1], value: hour, minVal: 0, maxVal: 23)
            && matchesField(fields[2], value: dom, minVal: 1, maxVal: 31)
            && matchesField(fields[3], value: month, minVal: 1, maxVal: 12)
            && matchesField(fields[4], value: dow, minVal: 0, maxVal: 6, allowSevenAsZero: true)
    }

    func evaluateScheduledHooks(now: Date = Date()) {
        let cal = Calendar.current
        let event = DoraxHookEvent(kind: .schedule)
        for pack in registry.packs {
            let cfg = registry.packConfig(for: pack.id)
            guard cfg.hooksEnabled else { continue }
            for hook in pack.metadata.hooks ?? [] where hook.on == .schedule {
                guard cfg.grantedPermissions.contains(hook.on.requiredPermission) else { continue }
                let key = HookKey(packID: pack.id, hookID: hook.id)
                guard disabledHooks[key] == nil else { continue }
                guard Self.matchesFilter(hook.filter, event: event) else { continue }

                var due = false
                if let every = hook.filter.every, let interval = Self.parseEveryInterval(every) {
                    if let last = lastScheduleFire[key] {
                        due = now.timeIntervalSince(last) >= interval
                    } else {
                        due = true
                    }
                } else if let cron = hook.filter.cron, Self.matchesCron(cron, date: now, calendar: cal) {
                    if let last = lastScheduleFire[key] {
                        due = !cal.isDate(last, equalTo: now, toGranularity: .minute)
                    } else {
                        due = true
                    }
                }
                guard due else { continue }
                lastScheduleFire[key] = now
                debounceTasks[key]?.cancel()
                debounceTasks[key] = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.executeHook(hook, in: pack, event: event)
                }
            }
        }
    }

    // MARK: - Dispatch (Debounced + Immediate Async)

    /// Dispatches an event with Guardrail 1 (Swift pre-filter) and Guardrail 2 (>=250ms debounce).
    func dispatch(_ event: DoraxHookEvent) {
        for pack in registry.packs {
            let cfg = registry.packConfig(for: pack.id)
            guard cfg.hooksEnabled else { continue }
            for hook in pack.metadata.hooks ?? [] where hook.on == event.kind {
                // Guardrail 2: consent check
                guard cfg.grantedPermissions.contains(hook.on.requiredPermission) else { continue }
                let key = HookKey(packID: pack.id, hookID: hook.id)
                // Guardrail 2: circuit breaker check
                guard disabledHooks[key] == nil else { continue }
                // Guardrail 1: Swift pre-filter BEFORE scheduling/spawning anything!
                guard Self.matchesFilter(hook.filter, event: event) else { continue }

                let delayMs = max(Self.minimumDebounceMs, hook.debounceMs ?? Self.minimumDebounceMs)
                debounceTasks[key]?.cancel()
                debounceTasks[key] = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    guard !Task.isCancelled, let self else { return }
                    await self.executeHook(hook, in: pack, event: event)
                }
            }
        }
    }

    /// Synchronous-await variant for deterministic testing (runs Guardrails 1, 2, 3 without waiting on debounce).
    func dispatchImmediatelyForTesting(_ event: DoraxHookEvent) async {
        for pack in registry.packs {
            let cfg = registry.packConfig(for: pack.id)
            guard cfg.hooksEnabled else { continue }
            for hook in pack.metadata.hooks ?? [] where hook.on == event.kind {
                guard cfg.grantedPermissions.contains(hook.on.requiredPermission) else { continue }
                let key = HookKey(packID: pack.id, hookID: hook.id)
                guard disabledHooks[key] == nil else { continue }
                guard Self.matchesFilter(hook.filter, event: event) else { continue }
                await executeHook(hook, in: pack, event: event)
            }
        }
    }

    // MARK: - Execution + Guardrail 2 (3s Timeout & 3-Crash Circuit Breaker) + Guardrail 3 (Suggest Only)

    private func executeHook(_ hook: DoraxPackHook, in pack: DoraxPackV2, event: DoraxHookEvent) async {
        let key = HookKey(packID: pack.id, hookID: hook.id)
        guard disabledHooks[key] == nil else { return }

        spawnedProcessCount += 1
        let started = Date()

        let result: Result<PluginRunResult, PluginRunFailure>
        if let customExec = processExecutor {
            result = await customExec(pack, hook, event, Self.hookTimeoutSeconds)
        } else {
            result = await runHookSubprocess(hook, in: pack, event: event)
        }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch result {
        case .failure(let failure):
            let newCount = (failureCounts[key] ?? 0) + 1
            failureCounts[key] = newCount
            runtime.appendLog(
                packID: pack.id, commandID: "hook:\(hook.id)", level: .error, durationMs: ms,
                message: "Hook failed (\(newCount)/\(Self.circuitBreakerFailureLimit)): \(failure.message)")
            if newCount >= Self.circuitBreakerFailureLimit {
                disabledHooks[key] = "Auto-disabled after \(newCount) consecutive crashes: \(failure.message)"
                runtime.appendLog(
                    packID: pack.id, commandID: "hook:\(hook.id)", level: .warning, durationMs: ms,
                    message: "Circuit breaker tripped — hook \(hook.id) disabled")
            }

        case .success(let run):
            failureCounts[key] = 0
            runtime.appendLog(
                packID: pack.id, commandID: "hook:\(hook.id)", level: .info, durationMs: ms,
                message: "Hook \(hook.id) fired on \(event.kind.rawValue)")
            applyHookOutput(stdout: run.stdout, pack: pack, hook: hook)
        }
    }

    private func runHookSubprocess(
        _ hook: DoraxPackHook,
        in pack: DoraxPackV2,
        event: DoraxHookEvent
    ) async -> Result<PluginRunResult, PluginRunFailure> {
        let scriptURL = pack.folderURL.appendingPathComponent(hook.script)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            return .failure(PluginRunFailure(message: "Hook script not found: \(hook.script)", kind: .launch))
        }
        let contextPayload = DoraxContextBridge.buildContext(
            pack: pack.metadata,
            commandID: "hook:\(hook.id)",
            includeSecrets: false,
            frontmostOverride: event.bundleID.map {
                DoraxContextPayload.FrontmostInfo(
                    appName: event.appName ?? $0,
                    bundleId: $0,
                    windowTitle: nil,
                    url: event.url,
                    domain: event.url.map { DoraxPackScope.normalizedHost(from: $0) })
            },
            clipboardOverride: event.clipboardText.map {
                DoraxContextPayload.ClipboardInfo(text: $0, type: event.clipboardType ?? "text")
            },
            selectionOverride: (!event.selectedFilePaths.isEmpty || event.selectedText != nil)
                ? DoraxContextPayload.SelectionInfo(text: event.selectedText, filePaths: event.selectedFilePaths)
                : nil)
        let stdinData = DoraxContextBridge.encodeJSON(contextPayload)
        let env: [String: String] = [
            "DORAX_PACK_ID": pack.id,
            "DORAX_HOOK_ID": hook.id,
            "DORAX_HOOK_EVENT": event.kind.rawValue,
            "DORAX_PACK_DIR": pack.folderURL.path,
        ]
        let ext = scriptURL.pathExtension.lowercased()
        let executable: String
        let args: [String]
        switch ext {
        case "py":
            executable = "/usr/bin/python3"; args = [scriptURL.path]
        case "sh", "zsh":
            executable = "/bin/zsh"; args = [scriptURL.path]
        case "js", "jxa":
            executable = "/usr/bin/osascript"; args = ["-l", "JavaScript", scriptURL.path]
        case "applescript":
            executable = "/usr/bin/osascript"; args = [scriptURL.path]
        default:
            executable = scriptURL.path; args = []
        }
        return await runner.runArgv(
            executable: executable,
            arguments: args,
            env: env,
            timeout: Self.hookTimeoutSeconds,
            workingDirectory: pack.folderURL.path,
            stdinData: stdinData)
    }

    /// Guardrail 3: only state patch, Notch wing/banner, Dock glow, or non-destructive staged suggestions.
    private func applyHookOutput(stdout: String, pack: DoraxPackV2, hook: DoraxPackHook) {
        isApplyingHookOutput = true
        defer { isApplyingHookOutput = false }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let output = try? JSONDecoder().decode(DoraxHookOutput.self, from: data)
        else { return }

        if let patch = output.state, !patch.isEmpty {
            var existing = lastHookState[pack.id] ?? [:]
            for (k, v) in patch { existing[k] = v }
            lastHookState[pack.id] = existing
        }

        if let notch = output.notch {
            DynamicNotchState.shared.publishPackActivity(
                DoraxNotchLiveActivity(packID: pack.id, packName: pack.name, payload: notch))
        }

        if let appearance = output.appearance, appearance.glow.normalized != .none {
            DockAuraEngine.shared.activate(
                id: "hook:\(pack.id):\(hook.id)",
                appearance: appearance,
                priority: 75,
                ttlSeconds: 8)
        }

        if let incoming = output.suggestions, !incoming.isEmpty {
            let tagged = incoming.map { s -> DoraxHookSuggestion in
                var copy = s
                copy.packID = pack.id
                return copy
            }
            // Replace previous suggestions from this pack, keep newest 8 total
            stagedSuggestions.removeAll { $0.packID == pack.id }
            stagedSuggestions.insert(contentsOf: tagged, at: 0)
            if stagedSuggestions.count > 8 {
                stagedSuggestions = Array(stagedSuggestions.prefix(8))
            }
        }
    }
}

// LauncherView+GeneralAIActions.swift
// Context-Dock
//
// DoraX Action Chat — General AI Chat integration for executable requests.
//
// Runs before the normal provider answer path in sendToAIProvider. When the user's
// message is an executable request ("open safari new private window"), this resolves
// real routes through GeneralAIActionResolver, shows route lookup status in the
// existing chat loading row, asks first-run approval (Allow Once / Always Allow /
// Cancel) inline, executes through GeneralAIActionExecutor, and returns an honest
// result message. Returns nil for non-executable queries so normal Q&A continues.

import SwiftUI
import EventKit
import Contacts

extension LauncherView {

    /// Executable-action interception for General AI Chat. Returns the final chat
    /// answer when the query was handled as a DoraX action, or nil to fall through
    /// to the normal provider pipeline.
    func generalAIExecutableActionAnswer(query: String) async -> String? {
        await MainActor.run { aiMode.loadingStatus = "Checking App Adapter capabilities…" }
        let resolution = await GeneralAIActionResolver.shared.resolve(query: query)

        switch resolution {
        case .none:
            // No deterministic route. If the user enabled a dedicated AppleScript model
            // (e.g. Osaurus AppleScript-8B) and this is an automation-shaped request,
            // let the specialist generate a script and run it with approval.
            if let scripted = await appleScriptModelFallbackAnswer(query: query) {
                return scripted
            }
            await MainActor.run {
                aiMode.loadingStatus = nil
                aiMode.actionProgress = nil
            }
            return nil

        case .explain(let message):
            await MainActor.run {
                aiMode.loadingStatus = nil
                aiMode.actionProgress = nil
                aiMode.pendingToolChips = ["DoraX route lookup"]
            }
            return message

        case .clarify(let question, let options):
            await MainActor.run {
                aiMode.loadingStatus = nil
                aiMode.actionProgress = nil
                aiMode.pendingToolChips = ["DoraX route lookup"]
            }
            guard !options.isEmpty else { return question }
            let list = options.map { "• \($0)" }.joined(separator: "\n")
            return question + "\n" + list

        case .candidates(let candidates):
            guard let best = candidates.first else {
                await MainActor.run {
                    aiMode.loadingStatus = nil
                    aiMode.actionProgress = nil
                }
                return nil
            }
            // Confirmed executable → NOW build the planner strip (never for plain Q&A).
            let discovered = discoveredRouteLabels(from: candidates)
            await MainActor.run {
                var progress = ActionProgress()
                progress.advance(to: "Understanding request")
                progress.advance(to: "Discovering capabilities")
                progress.discovered = discovered
                progress.advance(to: "Ranking routes")
                aiMode.actionProgress = progress
                aiMode.loadingStatus = "Ranking routes…"
            }
            // Medium confidence with meaningfully different alternatives → ask, UNLESS the
            // user has a proven learned preference for this exact intent (≥2 successes, no
            // failures) — then trust it and run instead of re-asking.
            if best.confidence < 0.7, !hasProvenLearnedRoute(best, query: query) {
                await MainActor.run {
                    aiMode.loadingStatus = nil
                    aiMode.actionProgress = nil
                    aiMode.pendingToolChips = ["DoraX route lookup"]
                }
                let list = candidates.prefix(3)
                    .map { "• \($0.title) — \($0.routeLabel)" }
                    .joined(separator: "\n")
                return "I found these possible actions — which one should I run?\n" + list
            }
            return await runGeneralAIAction(
                best, alternatives: Array(candidates.dropFirst()), query: query)

        case .compound(let appName, let bundleID, let steps):
            return await runCompoundAction(
                appName: appName, bundleID: bundleID, steps: steps)
        }
    }

    /// Execute an ordered compound plan ("save and quit vscode"): activate the app, warm its
    /// menu cache once if cold, then run each step through the normal candidate/approval/
    /// executor path. Stops at the first failed step and reports which one. Quit is verified
    /// by the app no longer running.
    private func runCompoundAction(appName: String, bundleID: String, steps: [String]) async -> String {
        await MainActor.run { aiMode.loadingStatus = "Planning \(appName) steps…" }

        // Activate (launch if needed) so menus/shortcuts land on the right app.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let app: NSRunningApplication?
        if let running {
            if running.isHidden { running.unhide() }
            running.activate(options: [.activateIgnoringOtherApps])
            app = running
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            app = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            app = nil
        }
        guard let app else {
            return "I couldn't open \(appName), so I didn't run the steps."
        }
        try? await Task.sleep(nanoseconds: 250_000_000)

        // Warm the menu cache once if it's cold — so we don't ask the user to "open the app
        // and try again". Background read, never an AX scan while typing.
        if AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: bundleID, appName: appName, query: "", maxResults: 1).isEmpty {
            await MainActor.run { aiMode.loadingStatus = "Reading \(appName) menus…" }
            await MenuWarmCacheService.shared.warm(app: app, force: true)
        }

        var completed: [String] = []
        for step in steps {
            await MainActor.run { aiMode.loadingStatus = "\(step.capitalized) in \(appName)…" }
            let ok = await runCompoundStep(
                step: step, appName: appName, bundleID: bundleID, app: app)
            if !ok {
                await MainActor.run {
                    aiMode.loadingStatus = nil
                    aiMode.pendingToolChips = ["Compound \(appName)", "Step failed: \(step)"]
                }
                let didPart = completed.isEmpty
                    ? "" : "I did \(completed.joined(separator: ", ")) first, but "
                return "\(didPart)the “\(step)” step in \(appName) didn't complete — I stopped there."
            }
            completed.append(step)
        }
        await MainActor.run {
            aiMode.loadingStatus = nil
            aiMode.pendingToolChips = ["Compound \(appName)", "Done"]
        }
        return "Done — \(completed.joined(separator: ", then ")) in \(appName)."
    }

    /// Run one compound step. Quit routes to a real quit and is verified by the app no longer
    /// running; other steps resolve to their best candidate and run through the executor. A
    /// cold cache that yields no route triggers one warm + retry.
    private func runCompoundStep(
        step: String, appName: String, bundleID: String, app: NSRunningApplication
    ) async -> Bool {
        if step == "quit" {
            app.terminate()
            try? await Task.sleep(nanoseconds: 700_000_000)
            let stillRunning = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .contains { !$0.isTerminated }
            if stillRunning {
                app.forceTerminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return !NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .contains { !$0.isTerminated }
        }

        func bestStepCandidate() -> DoraXActionCandidate? {
            GeneralAIActionResolver.shared.rankedStepCandidates(
                appName: appName, bundleID: bundleID, actionPhrase: step).first
        }
        var candidate = bestStepCandidate()
        if candidate == nil {
            // Cold cache → warm once, then retry.
            await MenuWarmCacheService.shared.warm(app: app, force: true)
            try? await Task.sleep(nanoseconds: 200_000_000)
            candidate = bestStepCandidate()
        }
        guard let candidate else { return false }

        if !GeneralAIActionApprovalStore.isAlwaysAllowed(candidate.permissionKey) {
            let decision = await GeneralAIActionApprovalCenter.shared.request(candidate: candidate)
            if decision == .cancel { return false }
        }
        let result = await GeneralAIActionExecutor.shared.execute(candidate)
        return result.success
    }

    /// True when the top candidate is a route the user has proven for this exact intent
    /// (≥2 verified successes, zero failures) — enough to skip the clarify prompt.
    private func hasProvenLearnedRoute(_ candidate: DoraXActionCandidate, query: String) -> Bool {
        let key = GeneralAIActionResolver.normalizedIntentKey(query)
        guard let stats = RouteConfidenceStore.shared.stats(
            intentKey: key,
            bundleID: candidate.bundleID ?? "",
            route: candidate.route.rawValue,
            capabilityID: candidate.capabilityID ?? "")
        else { return false }
        return stats.success >= 2 && stats.failure == 0
    }

    /// Distinct, human route names for the "Discovering capabilities" checklist, in the
    /// spec's preferred order.
    func discoveredRouteLabels(from candidates: [DoraXActionCandidate]) -> [String] {
        func label(_ route: DoraXActionCandidate.ExecutionRoute) -> String? {
            switch route {
            case .adapter: return "App Adapter"
            case .mcp: return "MCP"
            case .api: return "API"
            case .cli: return "CLI"
            case .shortcutRunner: return "Shortcut"
            case .keyboardShortcut: return "Keyboard Shortcut"
            case .verifiedMenu: return "Cached Menu"
            case .axFallback: return "Accessibility"
            case .automation: return "Automation"
            case .appLaunch: return nil  // a plain launch is not a "capability" to list
            }
        }
        let order = ["App Adapter", "MCP", "API", "CLI", "Shortcut", "Keyboard Shortcut",
                     "Cached Menu", "Automation", "Accessibility"]
        let found = Set(candidates.compactMap { label($0.route) })
        return order.filter(found.contains)
    }

    /// One-line reason for the chosen route, shown under "Selected best route".
    func routeReason(for route: DoraXActionCandidate.ExecutionRoute) -> String {
        switch route {
        case .adapter: return "Native capability"
        case .mcp: return "MCP tool"
        case .api: return "Connected API"
        case .cli: return "Command-line tool"
        case .shortcutRunner: return "macOS Shortcut"
        case .keyboardShortcut: return "Keyboard shortcut"
        case .verifiedMenu: return "Verified menu command"
        case .axFallback: return "Accessibility action"
        case .automation: return "App automation"
        case .appLaunch: return "App launch"
        }
    }

    /// Compact planner-progress strip for General AI Chat. Shows only reached stages with a
    /// ✓ (done) / spinner (active) / ✗ (failed), the discovered-route checklist, and the
    /// chosen route + reason. No token counts, no reasoning, no logs — launcher, not console.
    @ViewBuilder
    func actionProgressCard(_ progress: ActionProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(progress.steps.enumerated()), id: \.offset) { index, label in
                if index <= progress.completedCount {
                    let isDone = index < progress.completedCount
                        || progress.completedCount == progress.steps.count
                    HStack(spacing: 6) {
                        if isDone {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.green)
                                .frame(width: 12)
                        } else if progress.failed {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.orange)
                                .frame(width: 12)
                        } else {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        }
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(isDone ? .primary : .secondary)
                    }
                    if label == "Discovering capabilities", !progress.discovered.isEmpty {
                        ForEach(progress.discovered, id: \.self) { route in
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.green.opacity(0.8))
                                    .frame(width: 12)
                                Text(route)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 18)
                        }
                    }
                    if label == "Selected best route", let route = progress.selectedRoute {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(route)
                                .font(.caption2.weight(.semibold))
                            if let reason = progress.selectedReason {
                                Text("Reason: \(reason)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, 18)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .padding(.horizontal, 4)
    }

    private func runGeneralAIAction(
        _ candidate: DoraXActionCandidate,
        alternatives: [DoraXActionCandidate],
        query: String
    ) async -> String {
        let appLabel = candidate.appName ?? "app"
        let intentKey = GeneralAIActionResolver.normalizedIntentKey(query)
        // Local-only route-confidence learning: remember which route worked for this intent
        // so future ambiguous requests prefer it. Never sent to any AI provider.
        func learn(success: Bool) {
            RouteConfidenceStore.shared.record(
                intentKey: intentKey,
                bundleID: candidate.bundleID ?? "",
                route: candidate.route.rawValue,
                capabilityID: candidate.capabilityID ?? "",
                success: success)
        }
        // Failure-driven availability: a route that just worked is (re)marked available;
        // one that failed is skipped for a cooldown so the next ranking falls back.
        func mark(available: Bool, reason: String = "") {
            if available {
                CapabilityAvailabilityStore.shared.markAvailable(key: candidate.availabilityKey)
            } else {
                CapabilityAvailabilityStore.shared.markUnavailable(
                    key: candidate.availabilityKey, reason: reason)
                // A cached menu that failed live verification is stale — refresh that app's
                // menu cache in the background (never an AX scan while typing).
                if candidate.route == .verifiedMenu, let bundleID = candidate.bundleID,
                    let app = NSRunningApplication
                        .runningApplications(withBundleIdentifier: bundleID).first {
                    Task { await MenuWarmCacheService.shared.warm(app: app, force: true) }
                }
            }
        }
        await MainActor.run {
            aiMode.actionProgress?.advance(to: "Selected best route")
            aiMode.actionProgress?.selectedRoute = candidate.title
            aiMode.actionProgress?.selectedReason = routeReason(for: candidate.route)
            aiMode.loadingStatus = "Selected best route: \(candidate.routeLabel)"
        }
        // Route-specific first-run approval. "Always Allow" is scoped to this exact
        // permission key, never to the whole app.
        if !GeneralAIActionApprovalStore.isAlwaysAllowed(candidate.permissionKey) {
            await MainActor.run { aiMode.loadingStatus = "Approval required…" }
            let decision = await GeneralAIActionApprovalCenter.shared.request(candidate: candidate)
            if decision == .cancel {
                await MainActor.run {
                    aiMode.loadingStatus = nil
                    aiMode.actionProgress = nil
                    aiMode.pendingToolChips = ["Cancelled: \(candidate.routeLabel)"]
                }
                return "Cancelled — nothing was executed."
            }
        }

        await MainActor.run {
            aiMode.actionProgress?.advance(to: "Executing")
            aiMode.loadingStatus = generalAIExecutionStatus(for: candidate)
        }
        let result = await GeneralAIActionExecutor.shared.execute(candidate)

        if result.success {
            // Stage 7 — verify the write actually landed before claiming success.
            await MainActor.run {
                aiMode.actionProgress?.advance(to: "Verifying")
                aiMode.loadingStatus = "Verifying…"
            }
            let verification = await GeneralAIActionExecutor.shared.verify(candidate)
            await MainActor.run {
                aiMode.loadingStatus = nil
                switch verification {
                case .verified:
                    aiMode.actionProgress?.finish()
                    aiMode.pendingToolChips = ["\(candidate.title) · \(candidate.routeLabel)", "Verified"]
                case .skipped:
                    aiMode.actionProgress?.finish()
                    aiMode.pendingToolChips = [
                        "\(candidate.title) · \(candidate.routeLabel)", "Executor confirmed",
                    ]
                case .unverified:
                    aiMode.actionProgress?.failed = true
                    aiMode.pendingToolChips = [
                        "\(candidate.title) · \(candidate.routeLabel)", "Verification failed",
                    ]
                }
                aiMode.actionProgress = nil
            }
            switch verification {
            case .verified(let refined):
                learn(success: true)
                mark(available: true)
                // A cold menu cache initially resolves to an honest launch-only candidate.
                // Once launch is confirmed, warm that allowlisted app's menus and resolve
                // the original request again. This turns “open Calculator scientific” into
                // launch → verified shortcut/menu instead of stopping after launch.
                if candidate.route == .appLaunch, candidate.caveat != nil,
                    let bundleID = candidate.bundleID,
                    AppAdapterManager.shared.adapter(for: bundleID) != nil,
                    let app = NSRunningApplication
                        .runningApplications(withBundleIdentifier: bundleID)
                        .first(where: { !$0.isTerminated })
                {
                    await MainActor.run { aiMode.loadingStatus = "Reading \(appLabel) menus…" }
                    await MenuWarmCacheService.shared.warm(app: app, force: true)
                    let refreshed = await GeneralAIActionResolver.shared.resolve(query: query)
                    if case .candidates(let refreshedCandidates) = refreshed,
                        let menuCandidate = refreshedCandidates.first(where: {
                            $0.route != .appLaunch && $0.bundleID == bundleID
                        })
                    {
                        let followUp = await runGeneralAIAction(
                            menuCandidate,
                            alternatives: refreshedCandidates.filter { $0.id != menuCandidate.id },
                            query: query)
                        return "Opened \(appLabel) and confirmed it is active.\n\n" + followUp
                    }
                    await MainActor.run { aiMode.loadingStatus = nil }
                    let closest = AppMenuCapabilityCache.shared.menuItems(
                        bundleIdentifier: bundleID,
                        appName: appLabel,
                        query: "",
                        maxResults: 5
                    ).map(\.pathString)
                    let suggestion = closest.isEmpty
                        ? "No cached or live menu commands are available yet. Open the relevant view in \(appLabel), then refresh its App Adapter menu cache."
                        : "Closest available menus:\n" + closest.map { "• \($0)" }.joined(separator: "\n")
                    return "Opened \(appLabel) and confirmed it is active, but I couldn't find an exact menu or shortcut for this request. Nothing else was executed.\n\n\(suggestion)"
                }
                return refined ?? result.message
            case .skipped:
                // Executor succeeded; clearly disclose that no read-back verifier exists.
                learn(success: true)
                mark(available: true)
                return result.message
                    + "\n\nExecution receipt: executor confirmed success; this route has no independent read-back verification."
            case .unverified(let reason):
                learn(success: false)
                mark(available: false, reason: reason)
                let openHint = candidate.appName.map { " You can open \($0) to check." } ?? ""
                return "I completed the request, but I couldn't verify the final result. "
                    + "\(reason)\(openHint)"
            }
        }
        learn(success: false)
        mark(available: false, reason: result.message)
        await MainActor.run {
            aiMode.loadingStatus = nil
            aiMode.actionProgress = nil
            aiMode.pendingToolChips = ["\(candidate.title) · \(candidate.routeLabel)"]
        }
        var answer = "That didn't work: \(result.message)"
        if let fallback = alternatives.first {
            answer += "\n\nI also found a fallback route — \(fallback.title) "
                + "(\(fallback.routeLabel)). Say “try the fallback” and I'll run it."
        }
        return answer
    }

    /// Concise execution receipt shown in the shared chat shell. It describes only the
    /// concrete route DoraX is invoking; it is not model reasoning or a hidden prompt log.
    private func generalAIExecutionStatus(for candidate: DoraXActionCandidate) -> String {
        switch candidate.route {
        case .adapter:
            return "Running App Adapter action…"
        case .mcp:
            return "Running MCP tool…"
        case .api:
            return "Calling connected API…"
        case .cli:
            return "Running linked CLI…"
        case .shortcutRunner:
            return "Running macOS Shortcut…"
        case .keyboardShortcut:
            let display = MenuShortcutFormatter.display(
                char: candidate.shortcutChar,
                modifiers: candidate.shortcutModifiers)
            return display.map { "Running \($0)…" } ?? "Running keyboard shortcut…"
        case .verifiedMenu:
            if let display = MenuShortcutFormatter.display(
                char: candidate.shortcutChar,
                modifiers: candidate.shortcutModifiers)
            {
                return "Reading live menus, then running \(display)…"
            }
            return "Reading live menus…"
        case .axFallback:
            return "Running Accessibility action…"
        case .appLaunch:
            return "Launching \(candidate.appName ?? "app")…"
        case .automation:
            return "Running app automation…"
        }
    }

    /// Dedicated-automation-backend fallback: when no deterministic route matched, ask the
    /// specialist AppleScript model to generate a script, show it for approval, then run it.
    /// Returns nil (→ normal chat) when the model is off, unconfigured, or the query isn't
    /// an automation-shaped request.
    private func appleScriptModelFallbackAnswer(query: String) async -> String? {
        guard AppleScriptModelService.shared.isEnabledAndConfigured,
            GeneralAIActionResolver.shared.looksExecutable(query)
        else { return nil }

        let appHint = GeneralAIActionResolver.shared.namedInstalledApp(in: query)?.name
        await MainActor.run { aiMode.loadingStatus = "Generating AppleScript…" }
        let generated: AppleScriptModelService.GeneratedScript
        do {
            generated = try await AppleScriptModelService.shared.generateAppleScript(
                instruction: query, appHint: appHint)
        } catch {
            await MainActor.run { aiMode.loadingStatus = nil }
            // Model enabled but failed → tell the user honestly rather than falling back
            // silently to a chat guess.
            return "Couldn't generate AppleScript: "
                + (error.localizedDescription)
        }

        let preview = generated.script
        let firstLine = preview.split(separator: "\n").first.map(String.init) ?? "AppleScript"
        var candidate = DoraXActionCandidate(
            id: "automation.appleScriptModel",
            title: appHint.map { "Run AppleScript on \($0)" } ?? "Run generated AppleScript",
            appName: appHint,
            bundleID: nil,
            source: .automation,
            route: .automation,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .high,
            confidence: 0.9,
            permissionKey: "generalAI.execute.appleScriptModel",
            debugReason: "AppleScript model fallback: \(firstLine)"
        )
        candidate.inputValues = ["appleScript": preview]

        await MainActor.run { aiMode.loadingStatus = "Approval required…" }
        if !GeneralAIActionApprovalStore.isAlwaysAllowed(candidate.permissionKey) {
            let decision = await GeneralAIActionApprovalCenter.shared.request(candidate: candidate)
            if decision == .cancel {
                await MainActor.run {
                    aiMode.loadingStatus = nil
                    aiMode.pendingToolChips = ["Cancelled: AppleScript"]
                }
                return "Cancelled — nothing was executed.\n\nGenerated script was:\n```applescript\n"
                    + preview + "\n```"
            }
        }

        await MainActor.run { aiMode.loadingStatus = "Running AppleScript…" }
        let result = await GeneralAIActionExecutor.shared.execute(candidate)
        await MainActor.run {
            aiMode.loadingStatus = nil
            aiMode.pendingToolChips = ["AppleScript · automation model"]
        }
        if result.success {
            return result.message
        }
        return "That didn't work: \(result.message)\n\nGenerated script:\n```applescript\n"
            + preview + "\n```"
    }

    // MARK: - Route preference commands

    /// Parse an explicit route-preference command ("always use TextEdit for new text files",
    /// "avoid AX for Safari") and store it locally. Returns a confirmation to show in chat, or
    /// nil when the message isn't a preference command (normal flow continues). Never calls a
    /// provider; preferences only reorder routes and never bypass approval.
    func applyPreferenceCommand(query: String) async -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Unambiguous preference leads only. Bare "use …" is deliberately excluded — it's a
        // normal command ("use Safari to search …"), not a routing preference.
        let avoidLeads = ["avoid ", "don't use ", "dont use ", "never use ", "stop using "]
        let preferLeads = ["always use ", "always prefer ", "prefer "]
        let strength: RoutePreference.Strength
        var rest: String
        if let lead = avoidLeads.first(where: { q.hasPrefix($0) }) {
            strength = .avoid
            rest = String(q.dropFirst(lead.count))
        } else if let lead = preferLeads.first(where: { q.hasPrefix($0) }) {
            strength = .preferred
            rest = String(q.dropFirst(lead.count))
        } else {
            return nil
        }

        var target = rest
        var context = ""
        for sep in [" for ", " when ", " with ", " in "] {
            if let range = rest.range(of: sep) {
                target = String(rest[..<range.lowerBound])
                context = String(rest[range.upperBound...])
                break
            }
        }
        target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        // Require an explicit scope ("… for/when …") so we never turn a stray sentence into
        // a preference.
        guard !target.isEmpty, !context.isEmpty else { return nil }

        var bundleID: String?
        var route: String?
        if target.contains("ax") || target.contains("accessibility") {
            route = "axFallback"
        } else if target.contains("menu") {
            route = "verifiedMenu"
        } else if target.contains("keyboard") || target.contains("hotkey") {
            route = "keyboardShortcut"
        } else if TerminalPackageManager.shared.findPackageForQuery(target)?.isInstalled == true {
            route = "cli"
        } else if let app = GeneralAIActionResolver.shared.namedInstalledApp(in: target) {
            bundleID = app.bundleId
        }

        var intentKey = ""
        if route != nil {
            // A route rule ("avoid AX for Safari") — the context names the app scope.
            if !context.isEmpty,
                let app = GeneralAIActionResolver.shared.namedInstalledApp(in: context) {
                bundleID = app.bundleId
            } else if !context.isEmpty {
                intentKey = GeneralAIActionResolver.normalizedIntentKey(context)
            }
        } else if !context.isEmpty {
            // An app/tool rule — the context is the intent it applies to.
            intentKey = GeneralAIActionResolver.normalizedIntentKey(context)
        }

        guard bundleID != nil || route != nil else { return nil }
        RoutePreferenceStore.shared.set(
            intentKey: intentKey, bundleID: bundleID, route: route, strength: strength)

        let verb = strength == .preferred ? "prefer" : "avoid"
        let scope = context.isEmpty ? "" : " for \(context)"
        await MainActor.run { aiMode.pendingToolChips = ["Preference saved"] }
        return "Got it — I'll \(verb) \(target)\(scope). You can change this anytime by telling me a new preference."
    }

    // MARK: - Read-only personal-data privacy gate

    /// Personal-data sources General Chat can read. Each gets its own first-run approval
    /// so "any unread messages?" or "events this week?" ask before touching private data.
    enum ReadOnlyDataDomain: String, Equatable {
        case messages, mail, calendar, reminders, contacts, notes, photos
        var displayName: String {
            switch self {
            case .messages: return "Messages"
            case .mail: return "Mail"
            case .calendar: return "Calendar"
            case .reminders: return "Reminders"
            case .contacts: return "Contacts"
            case .notes: return "Notes"
            case .photos: return "Photos"
            }
        }
        /// macOS-style one-line justification shown under the approval prompt.
        var approvalSubtitle: String {
            switch self {
            case .messages: return "DoraX will read your unread messages to answer this request."
            case .mail: return "DoraX will read your Mail to answer this request."
            case .calendar: return "DoraX will read your upcoming events."
            case .reminders: return "DoraX will read your reminders."
            case .contacts: return "DoraX will read your contacts to answer this request."
            case .notes: return "DoraX will read your notes to answer this request."
            case .photos: return "DoraX will read photo metadata to answer your request."
            }
        }
    }

    /// Classify a message as a read-only request against one personal-data source, or nil.
    /// Requires BOTH a data-source keyword AND a read/possessive signal so plain questions
    /// ("what is email?") don't trip it. Never runs AX or the provider — pure string match.
    func readOnlyDataDomain(for query: String) -> ReadOnlyDataDomain? {
        let q = query.lowercased()
        let readSignals = [
            "my ", "any ", "unread", "recent", "upcoming", "do i have", "did i",
            "show me", "list ", "check ", "what's on", "whats on", "how many",
            "this week", "today", "tomorrow", "latest",
        ]
        guard readSignals.contains(where: q.contains) else { return nil }
        let map: [(ReadOnlyDataDomain, [String])] = [
            (.messages, ["message", "imessage", "text from", "texts", "unread text"]),
            (.mail, ["email", "mail", "inbox"]),
            (.calendar, ["calendar", "event", "meeting", "schedule", "appointment"]),
            (.reminders, ["reminder", "to-do", "todo", "task"]),
            (.contacts, ["contact", "phone number", "email address of"]),
            (.notes, ["note about", "notes about", "my note", "my notes"]),
            (.photos, ["photo", "picture", "screenshot", "image of mine"]),
        ]
        for (domain, keywords) in map where keywords.contains(where: q.contains) {
            return domain
        }
        return nil
    }

    /// Read-only capability router. Classifies a personal-data read request, asks first-run
    /// approval, then READS the real data through the local capability (EventKit / Contacts)
    /// and grounds the provider in it — so the provider only summarizes verified data and can
    /// never answer "I don't have access." Returns:
    ///   - a grounded answer string when handled here,
    ///   - a denial string when the user cancels,
    ///   - nil to fall through (not a read request, or a domain with no direct read yet — it
    ///     is already approved, so the existing enrichment/tool-loop reads it).
    func readOnlyCapabilityAnswer(query: String) async -> String? {
        if let domain = readOnlyDataDomain(for: query) {
            guard await requestReadApproval(domain: domain) else {
                return "I won't read your \(domain.displayName) without permission. "
                    + "Ask again and choose Allow to let me."
            }
            switch domain {
            case .messages: return await messagesReadAnswer(query: query)
            case .calendar: return await calendarReadAnswer(query: query)
            case .reminders: return await remindersReadAnswer(query: query)
            case .contacts: return await contactsReadAnswer(query: query)
            default:
                // Approved, but no direct local read wired yet — let the existing Apple-data
                // enrichment / tool-loop fetch it (they read via MCP/automation).
                return nil
            }
        }

        return await groundedCapabilityReadAnswer(query: query)
    }

    /// Reads recent Messages locally through the built-in Apple MCP. Apple does not expose
    /// a reliable public unread flag, so unread-only questions are answered honestly while
    /// still returning recent conversation evidence instead of provider speculation.
    private func messagesReadAnswer(query: String) async -> String {
        guard AppSettings.shared.messagesMCPEnabled else {
            return "Messages access is disabled. Enable DoraX Apple MCP · Messages in Settings → App Adapters → Messages → Tools."
        }
        let lower = query.lowercased()
        let contact: String = {
            for marker in [" from ", " by "] {
                if let range = lower.range(of: marker) {
                    return String(query[range.upperBound...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,"))
                }
            }
            return ""
        }()
        let snapshot = await Task.detached(priority: .userInitiated) {
            MessagesAutomation.conversationSnapshot(contactFilter: contact, limit: 20)
        }.value
        if lower.contains("unread") {
            return """
                DoraX can read recent Messages conversations, but Apple does not expose a reliable unread flag through its supported Messages automation interface. I won't guess unread status.

                Recent conversation evidence:
                \(snapshot)
                """
        }
        return snapshot
    }

    /// First-run read approval for a personal-data source. Returns false only on Cancel.
    private func requestReadApproval(domain: ReadOnlyDataDomain) async -> Bool {
        let permissionKey = "generalAI.read.\(domain.rawValue)"
        if GeneralAIActionApprovalStore.isAlwaysAllowed(permissionKey) { return true }
        var candidate = DoraXActionCandidate(
            id: "read.\(domain.rawValue)",
            title: domain.displayName,
            appName: domain.displayName,
            bundleID: nil,
            source: .system,
            route: .automation,
            capabilityID: nil,
            requiredInputs: [],
            riskLevel: .low,
            confidence: 1.0,
            permissionKey: permissionKey,
            debugReason: "read-only \(domain.rawValue) access")
        candidate.caveat = domain.approvalSubtitle
        await MainActor.run {
            aiMode.loadingStatus = "Approval required to read \(domain.displayName)…"
        }
        let decision = await GeneralAIActionApprovalCenter.shared.request(candidate: candidate)
        await MainActor.run { aiMode.loadingStatus = nil }
        return decision != .cancel
    }

    /// General read-capability path for app adapters, cached menu knowledge, MCP/API/CLI,
    /// and skills metadata. Discovery is done by GeneralAIActionResolver using cached
    /// metadata only; this function only reads the selected grounded source.
    private func groundedCapabilityReadAnswer(query: String) async -> String? {
        let candidates = await GeneralAIActionResolver.shared.resolveReadCandidates(query: query)
        guard !candidates.isEmpty else { return nil }

        if shouldClarifyReadCandidates(candidates, query: query) {
            let options = candidates.prefix(4).compactMap { candidate -> String? in
                guard let appName = candidate.appName else { return nil }
                let semantic = candidate.semanticType?.displayName ?? "data"
                return "\(semantic) in \(appName)"
            }
            if !options.isEmpty {
                return "I found multiple places that could answer this: "
                    + options.joined(separator: ", ")
                    + ". Which one should I read?"
            }
        }

        let candidate = candidates[0]
        guard await requestReadApproval(candidate: candidate) else {
            return "I won't read \(candidate.appName ?? "that app") without permission."
        }

        let intentKey = GeneralAIActionResolver.normalizedIntentKey(query)
        let readResult = await readGroundedCandidate(candidate)
        switch readResult {
        case .success(let dataLabel, let dataBlock):
            RouteConfidenceStore.shared.record(
                intentKey: intentKey,
                bundleID: candidate.bundleID ?? "",
                route: candidate.route.rawValue,
                capabilityID: candidate.capabilityID ?? "",
                success: true
            )
            CapabilityAvailabilityStore.shared.markAvailable(key: candidate.availabilityKey)
            return await summarizeGroundedData(
                userQuery: query,
                dataLabel: dataLabel,
                dataBlock: dataBlock
            )
        case .failure(let message):
            RouteConfidenceStore.shared.record(
                intentKey: intentKey,
                bundleID: candidate.bundleID ?? "",
                route: candidate.route.rawValue,
                capabilityID: candidate.capabilityID ?? "",
                success: false
            )
            CapabilityAvailabilityStore.shared.markUnavailable(
                key: candidate.availabilityKey,
                reason: message
            )
            return message
        }
    }

    private func shouldClarifyReadCandidates(
        _ candidates: [DoraXActionCandidate],
        query: String
    ) -> Bool {
        guard GeneralAIActionResolver.shared.namedInstalledApp(in: query) == nil,
              candidates.count > 1
        else { return false }
        let first = candidates[0]
        let peers = candidates.prefix(3).filter {
            $0.semanticType == first.semanticType
                && $0.source == first.source
                && $0.bundleID != first.bundleID
                && abs($0.confidence - first.confidence) < 0.05
        }
        return peers.count > 1
    }

    private func requestReadApproval(candidate: DoraXActionCandidate) async -> Bool {
        if GeneralAIActionApprovalStore.isAlwaysAllowed(candidate.permissionKey) { return true }
        var approvalCandidate = candidate
        approvalCandidate.caveat =
            "DoraX will read \(candidate.readSourceLabel ?? candidate.source.rawValue) data"
            + (candidate.appName.map { " from \($0)" } ?? "")
            + " to answer this request."
        await MainActor.run {
            aiMode.loadingStatus = "Approval required to read \(candidate.appName ?? "app data")…"
        }
        let decision = await GeneralAIActionApprovalCenter.shared.request(candidate: approvalCandidate)
        await MainActor.run { aiMode.loadingStatus = nil }
        return decision != .cancel
    }

    private enum GroundedReadResult {
        case success(dataLabel: String, dataBlock: String)
        case failure(String)
    }

    private func readGroundedCandidate(_ candidate: DoraXActionCandidate) async -> GroundedReadResult {
        let appLabel = candidate.appName ?? "DoraX"
        let semantic = candidate.semanticType?.displayName ?? "data"
        let source = candidate.readSourceLabel ?? candidate.source.rawValue
        let label = "\(semantic) from \(appLabel) via \(source)"

        switch candidate.source {
        case .cachedMenu:
            let data = candidate.readContext
                ?? candidate.readValues.enumerated()
                    .map { "\($0.offset + 1). \($0.element)" }
                    .joined(separator: "\n")
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failure("I found \(appLabel)'s cached menu group, but it had no readable items.")
            }
            return .success(dataLabel: label, dataBlock: trimmed)

        case .appAdapter:
            guard let bundleID = candidate.bundleID else {
                return .failure("The adapter read route is missing its app.")
            }
            await MainActor.run { aiMode.loadingStatus = "Reading \(appLabel) adapter…" }
            let results = await AppAdapterManager.shared.runContextReaders(
                for: bundleID,
                axContext: AXContextReader.shared.current
            )
            await MainActor.run { aiMode.loadingStatus = nil }
            let selected = candidate.capabilityID.flatMap { results[$0] }
            let data = selected ?? results
                .sorted { $0.key < $1.key }
                .map { "### \($0.key)\n\($0.value)" }
                .joined(separator: "\n\n")
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failure("\(appLabel)'s adapter reader returned no data.")
            }
            return .success(dataLabel: label, dataBlock: trimmed)

        case .mcp:
            guard let bundleID = candidate.bundleID,
                  let server = candidate.inputValues["mcpServer"],
                  let tool = candidate.inputValues["mcpTool"]
            else { return .failure("The MCP read route is incomplete.") }
            await MainActor.run { aiMode.loadingStatus = "Reading \(appLabel) MCP…" }
            do {
                let output = try await MCPRuntime.shared.callTool(
                    bundleId: bundleID,
                    server: server,
                    tool: tool,
                    arguments: [:]
                )
                await MainActor.run { aiMode.loadingStatus = nil }
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return .failure("\(tool) returned no data.")
                }
                return .success(dataLabel: label, dataBlock: String(trimmed.prefix(12_000)))
            } catch {
                await MainActor.run { aiMode.loadingStatus = nil }
                return .failure("MCP read failed: \(error.localizedDescription)")
            }

        case .cli:
            guard candidate.inputValues["command"]?.isEmpty == false else {
                return .failure("The CLI read route has no command.")
            }
            await MainActor.run { aiMode.loadingStatus = "Running \(appLabel) CLI read…" }
            let result = await GeneralAIActionExecutor.shared.execute(candidate)
            await MainActor.run { aiMode.loadingStatus = nil }
            guard result.success else { return .failure(result.message) }
            let trimmed = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure("The CLI returned no data.") }
            return .success(dataLabel: label, dataBlock: String(trimmed.prefix(12_000)))

        default:
            if let data = candidate.readContext?.trimmingCharacters(in: .whitespacesAndNewlines),
               !data.isEmpty {
                return .success(dataLabel: label, dataBlock: data)
            }
            return .failure("I found a read route for \(appLabel), but it did not expose readable data.")
        }
    }

    // MARK: - Calendar / Reminders / Contacts reads

    private func calendarReadAnswer(query: String) async -> String? {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized || status == .writeOnly else {
            return "I don't have Calendar access yet. Turn it on in System Settings → Privacy & "
                + "Security → Calendars → Context-Dock, then ask again."
        }
        await MainActor.run { aiMode.loadingStatus = "Reading your Calendar…" }
        let q = query.lowercased()
        let cal = Calendar.current
        let events: [[String: Any]]
        let rangeLabel: String
        if q.contains("today") {
            events = AppleAppsAPI.shared.getTodayEvents()
            rangeLabel = "today"
        } else if q.contains("tomorrow"),
            let start = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())),
            let end = cal.date(byAdding: .day, value: 1, to: start) {
            events = AppleAppsAPI.shared.getEvents(from: start, to: end)
            rangeLabel = "tomorrow"
        } else {
            events = AppleAppsAPI.shared.getCalendarEvents(limit: 25)
            rangeLabel = "in the next 7 days"
        }
        await MainActor.run { aiMode.loadingStatus = nil }
        guard !events.isEmpty else { return "You have no events \(rangeLabel)." }

        let lines = events.prefix(25).map { event -> String in
            let title = (event["title"] as? String) ?? "(untitled)"
            let when = (event["startDate"] as? String).flatMap(Self.friendlyISODate) ?? ""
            let loc = (event["location"] as? String).map { $0.isEmpty ? "" : " @ \($0)" } ?? ""
            return "• \(title)\(when.isEmpty ? "" : " — \(when)")\(loc)"
        }.joined(separator: "\n")
        return await summarizeGroundedData(
            userQuery: query, dataLabel: "calendar events \(rangeLabel)", dataBlock: lines)
    }

    private func remindersReadAnswer(query: String) async -> String? {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        guard status == .fullAccess || status == .authorized || status == .writeOnly else {
            return "I don't have Reminders access yet. Turn it on in System Settings → Privacy & "
                + "Security → Reminders → Context-Dock, then ask again."
        }
        await MainActor.run { aiMode.loadingStatus = "Reading your Reminders…" }
        let items = await Task.detached(priority: .utility) {
            await AppleAppsAPI.shared.getReminders(limit: 30)
        }.value
        await MainActor.run { aiMode.loadingStatus = nil }
        guard !items.isEmpty else { return "You have no open reminders." }
        let lines = items.prefix(30).map { item -> String in
            let title = (item["title"] as? String) ?? "(untitled)"
            let due = (item["dueDate"] as? String).flatMap(Self.friendlyISODate) ?? ""
            return "• \(title)\(due.isEmpty ? "" : " — due \(due)")"
        }.joined(separator: "\n")
        return await summarizeGroundedData(
            userQuery: query, dataLabel: "reminders", dataBlock: lines)
    }

    private func contactsReadAnswer(query: String) async -> String? {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else {
            return "I don't have Contacts access yet. Turn it on in System Settings → Privacy & "
                + "Security → Contacts → Context-Dock, then ask again."
        }
        await MainActor.run { aiMode.loadingStatus = "Reading your Contacts…" }
        let all = await ContactSearchManager.shared.getAllContacts()
        await MainActor.run { aiMode.loadingStatus = nil }
        // Match by any significant query token against contact names.
        let stop: Set<String> = [
            "find", "contact", "number", "phone", "email", "address", "of", "for", "the",
            "what", "is", "get", "me", "show", "my",
        ]
        let tokens = query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 && !stop.contains($0) }
        let matches = all.filter { contact in
            tokens.contains { contact.fullName.lowercased().contains($0) }
        }
        guard !matches.isEmpty else {
            return "I couldn't find a matching contact for that."
        }
        let lines = matches.prefix(8).map { c -> String in
            var parts = ["• \(c.fullName)"]
            if !c.primaryPhone.isEmpty { parts.append("  📞 \(c.primaryPhone)") }
            if !c.primaryEmail.isEmpty { parts.append("  ✉️ \(c.primaryEmail)") }
            return parts.joined(separator: "\n")
        }.joined(separator: "\n")
        return await summarizeGroundedData(
            userQuery: query, dataLabel: "contacts", dataBlock: lines)
    }

    /// Ground the selected provider in locally-read data for summarization only. The provider
    /// never fetches — it reasons over verified data and must not claim it lacks access. Falls
    /// back to the raw list if the provider errors or returns nothing.
    private func summarizeGroundedData(
        userQuery: String, dataLabel: String, dataBlock: String
    ) async -> String {
        let systemPrompt =
            "You are DoraX. The user's REAL \(dataLabel) were just read locally by DoraX and are "
            + "listed below. Answer the user's question concisely using ONLY this data. NEVER say "
            + "you lack access or can't read it — DoraX already read it for you.\n\n\(dataBlock)"
        await MainActor.run { aiMode.loadingStatus = "Summarizing…" }
        defer { Task { @MainActor in aiMode.loadingStatus = nil } }
        do {
            let answer = try await AIProviderRouter.shared.sendPrepared(
                provider: settings.selectedAIProvider,
                message: userQuery,
                context: .none,
                contextPrompt: systemPrompt)
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? dataBlock : trimmed
        } catch {
            // Provider unavailable → still give the user their real data.
            return dataBlock
        }
    }

    private static func friendlyISODate(_ iso: String) -> String? {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(date) { day = "today" }
        else if cal.isDateInTomorrow(date) { day = "tomorrow" }
        else {
            let df = DateFormatter()
            df.dateFormat = "EEE MMM d"
            day = df.string(from: date)
        }
        let tf = DateFormatter()
        tf.timeStyle = .short
        return "\(day) \(tf.string(from: date))"
    }
}

// MARK: - Named-app runtime grounding

extension LauncherView {

    /// Live app-state context for General Chat questions about a named app
    /// ("what's going on with vs code?"). Pulls the SAME powers frontmost-app chat
    /// already uses — adapter context readers, runtime CLI snapshots (code --status,
    /// imsg, tailscale), the menu capability cache, MCP/adapter inventory — so the
    /// provider answers from real state instead of "unable to access application status".
    /// Returns "" when the query names no installed app or isn't status-shaped.
    func generalAppRuntimeContextBlock(for query: String) async -> String {
        let lowered = query.lowercased()
        guard let app = GeneralAIActionResolver.shared.namedInstalledApp(in: query) else {
            return ""
        }
        // Only status/state questions pay for live reads.
        let statusWords = [
            "what", "doing", "going on", "status", "open", "current", "working",
            "why", "running", "which", "how many", "show", "recent", "state",
            "explore", "inspect", "pause", "play", "song", "track", "music",
        ]
        guard statusWords.contains(where: lowered.contains) else { return "" }

        await MainActor.run { aiMode.loadingStatus = "Reading \(app.name) state…" }
        var lines: [String] = [
            "## Live \(app.name) state (read by DoraX just now — factual)",
        ]

        // Running / frontmost state.
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: app.bundleId).first
        if let running {
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app.bundleId
            lines.append("- \(app.name) is running\(frontmost ? " and frontmost" : "")"
                + (running.isHidden ? " (hidden)" : ""))
        } else {
            lines.append("- \(app.name) is NOT running right now")
        }

        let mediaInfo = await MediaRemoteBridge.shared.infoAsync()
        let media = MediaRemoteBridge.parse(mediaInfo)
        let mediaClient = await MediaRemoteBridge.shared.clientAsync()
        let observerMediaApp = MediaPlayerObserver.shared.appName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if mediaClient.bundleID == app.bundleId
            || mediaClient.displayName?.localizedCaseInsensitiveContains(app.name) == true
            || (!observerMediaApp.isEmpty
                && app.name.localizedCaseInsensitiveContains(observerMediaApp)) {
            let title = media.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                let artist = media.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(
                    "- \(app.name) now playing: \(title)"
                    + (artist.isEmpty ? "" : " by \(artist)")
                    + (media.isPlaying ? " (playing)" : " (paused)")
                )
            }
        }

        // Adapter context readers — the same live readers frontmost-app chat runs
        // (current file, git branch, workspace, …).
        if AppAdapterManager.shared.adapter(for: app.bundleId) != nil, running != nil {
            let readerData = await AppAdapterManager.shared.runContextReaders(
                for: app.bundleId, axContext: AXContextReader.shared.current)
            for (_, value) in readerData.sorted(by: { $0.key < $1.key })
            where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(String(value.prefix(600)))
            }
        }

        // Runtime CLI snapshots: VS Code `code --status`, Messages imsg, Tailscale CLI.
        let cliSnapshot = await runtimeAppCLIContextPrompt(
            bundleId: app.bundleId, appName: app.name, query: query)
        if !cliSnapshot.isEmpty {
            lines.append("")
            lines.append(cliSnapshot)
        }

        // Compact capability inventory so the model knows what DoraX can DO with
        // this app (and offers real next actions instead of "check their website").
        var inventory: [String] = []
        let adapterActions = AppAdapterManager.shared.actions(for: app.bundleId)
        if !adapterActions.isEmpty {
            inventory.append(
                "\(adapterActions.count) adapter actions ("
                + adapterActions.prefix(6).map(\.name).joined(separator: ", ") + "…)")
        }
        let mcpServers = MCPServerManager.shared.servers(forBundleId: app.bundleId)
        if !mcpServers.isEmpty {
            inventory.append("\(mcpServers.count) linked MCP server(s)")
        }
        if let summary = AppMenuCapabilityCache.shared.summary(bundleIdentifier: app.bundleId) {
            inventory.append("\(summary.recordCount) cached menu commands")
        }
        if !inventory.isEmpty {
            lines.append("")
            lines.append("DoraX capabilities registered for \(app.name): "
                + inventory.joined(separator: "; ") + ".")
        }

        lines.append("")
        lines.append(
            "Answer the user's question about \(app.name) from the data above. "
            + "If something isn't in the data, say DoraX couldn't read that specific detail — "
            + "NEVER reply \"unable to access application status\" and never answer from "
            + "generic product knowledge when live state is shown here.")
        await MainActor.run {
            aiMode.pendingToolChips.append("\(app.name) live state")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Inline approval card

/// First-run approval card shown inside the General Chat surface (no new floating
/// window). Observes the approval center directly so the huge LauncherView struct
/// doesn't need a new @State/@ObservedObject property.
struct GeneralAIActionApprovalCard: View {
    @ObservedObject private var center = GeneralAIActionApprovalCenter.shared

    var body: some View {
        if let pending = center.pending {
            let candidate = pending.candidate
            // Read-only data approvals read as a permission prompt, not an action to run.
            let isReadApproval = candidate.id.hasPrefix("read.")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: isReadApproval ? "lock.shield" : "checkmark.shield")
                        .foregroundStyle(.orange)
                    Text(
                        isReadApproval
                            ? "Allow DoraX to read your \(candidate.title)?"
                            : "Run \(candidate.title)?"
                    )
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                }
                if isReadApproval {
                    if let subtitle = candidate.caveat, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Route: \(candidate.routeLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let path = candidate.menuPath, !path.isEmpty {
                    Text(path.joined(separator: " → "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Generated AppleScript gets a full, scrollable preview so the user sees
                // exactly what will run before approving arbitrary automation.
                if let script = candidate.inputValues["appleScript"],
                    !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("This script will run:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(script)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 160)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
                HStack(spacing: 8) {
                    Button("Allow Once") {
                        GeneralAIActionApprovalCenter.shared.resolve(.allowOnce)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Always Allow") {
                        GeneralAIActionApprovalCenter.shared.resolve(.allowAlways)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(isReadApproval ? "Don't Allow" : "Cancel", role: .cancel) {
                        GeneralAIActionApprovalCenter.shared.resolve(.cancel)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.orange.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
                    )
            )
        }
    }
}

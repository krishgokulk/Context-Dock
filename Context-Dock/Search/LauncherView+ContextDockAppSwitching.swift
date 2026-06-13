import AppKit
import SwiftUI

extension LauncherView {
    func buildContextDockApplicationSwitchPills(query: String) -> [DockPill] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = normalizedDockPillText(q)
        guard showContextInDock,
            !isGlobalContextActive,
            !showMediaLayer,
            !aiMode.isActive
        else {
            return []
        }

        struct Candidate {
            let name: String
            let bundleId: String?
            let path: String?
            let icon: NSImage?
            let isRunning: Bool
            let runningApp: NSRunningApplication?
            let order: Int
        }

        var candidates: [Candidate] = []
        var seen = Set<String>()

        func add(
            name: String,
            bundleId: String?,
            path: String?,
            icon: NSImage?,
            isRunning: Bool,
            runningApp: NSRunningApplication?,
            order: Int
        ) {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard bundleId != Bundle.main.bundleIdentifier else { return }
            guard bundleId != "com.apple.finder" else { return }
            guard bundleId != frontmost.bundleID else { return }
            guard !shouldIgnoreApplicationFromAppSearch(
                appName: name,
                bundleIdentifier: bundleId,
                path: path
            ) else { return }
            if !normalizedQuery.isEmpty {
                guard appSearchMatchScore(query: q, appName: name, bundleIdentifier: bundleId) != nil
                else { return }
            }

            let key = bundleId ?? path ?? normalizedDockPillText(name)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            candidates.append(
                Candidate(
                    name: name,
                    bundleId: bundleId,
                    path: path,
                    icon: icon,
                    isRunning: isRunning,
                    runningApp: runningApp,
                    order: order
                ))
        }

        let runningSource = runningRegularApps.isEmpty ? currentRegularRunningApps() : runningRegularApps
        for (index, app) in runningSource.enumerated() {
            add(
                name: app.localizedName ?? "",
                bundleId: app.bundleIdentifier,
                path: app.bundleURL?.path,
                icon: resolvedRunningAppIcon(for: app),
                isRunning: true,
                runningApp: app,
                order: index
            )
        }

        return candidates
            .sorted {
                let lhs =
                    (normalizedQuery.isEmpty
                        ? AppUsageLearner.shared.score(forBundleID: $0.bundleId ?? "")
                        : (appSearchMatchScore(
                            query: q, appName: $0.name, bundleIdentifier: $0.bundleId) ?? 0))
                    + ($0.isRunning ? 400 : 0)
                let rhs =
                    (normalizedQuery.isEmpty
                        ? AppUsageLearner.shared.score(forBundleID: $1.bundleId ?? "")
                        : (appSearchMatchScore(
                            query: q, appName: $1.name, bundleIdentifier: $1.bundleId) ?? 0))
                    + ($1.isRunning ? 400 : 0)
                if lhs != rhs { return lhs > rhs }
                return $0.order < $1.order
            }
            .prefix(6)
            .map { candidate in
                var pill = DockPill(
                    id: "context-app-switch-\(candidate.bundleId ?? candidate.path ?? candidate.name)",
                    name: candidate.name,
                    icon: "app",
                    accentColorName: "blue",
                    badge: "Switch",
                    execute: {
                        if let runningApp = candidate.runningApp, !runningApp.isTerminated {
                            self.activateRunningAppFromDock(runningApp)
                        }
                    }
                )
                pill.menuItemImage =
                    candidate.icon
                    ?? resolvedApplicationIcon(
                        bundleIdentifier: candidate.bundleId,
                        appName: candidate.name
                    )
                pill.sourceBundleId = candidate.bundleId ?? ""
                pill.sourceAppName = candidate.name
                pill.rankingKind = "appSwitch"
                pill.trackingIdentifier =
                    "context-app-switch:\(candidate.bundleId ?? candidate.path ?? normalizedDockPillText(candidate.name))"
                pill.searchTerms = [
                    candidate.name,
                    candidate.bundleId ?? "",
                    "switch",
                    "application",
                ]
                return pill
            }
    }
}

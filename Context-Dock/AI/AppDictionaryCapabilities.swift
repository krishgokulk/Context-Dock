// AppDictionaryCapabilities.swift
// Context-Dock
//
// The dictionary rung's two capabilities, one per learned scripting app:
//   dict.query.<bundleID>   — typed reads (low: runs at once)
//   dict.modify.<bundleID>  — typed writes (medium: the gate card)
//
// Registered from the learned store on every chat preflight, the way the built-in MCP
// families are — so the manifest an app's own sdef taught DoraX is what the model sees,
// not a hand-written adapter. An app DoraX already serves through a built-in adapter
// keeps that adapter and gets no dictionary capability: the rung is for apps without
// one (plan §2c day-one table).
//
// Sends are impossible by construction: the typed verbs are query/count/set/make/delete
// only, and an unknown verb is refused. Anything the dictionary classifies outbound
// (send, reply, forward, redirect…) is never rendered into a script at all.

import AppKit
import Foundation

@MainActor
enum AppDictionaryCapabilities {

    private static let queryPrefix = "dict.query."
    private static let modifyPrefix = "dict.modify."
    /// Every capability this rung owns. Used by contract tests that must tell a learned
    /// dictionary route apart from an adapter's own typed write.
    static let idPrefix = "dict."

    /// Drop stale registrations and register one pair of capabilities per learned
    /// dictionary that has readable classes. Called from
    /// `CapabilityRegistry.refreshBuiltInMCPs` on every preflight, so it must be cheap:
    /// reads an in-memory map, no subprocess (a scan stores the manifest, this only
    /// reads it).
    static func registerLearned(in registry: CapabilityRegistry) {
        registry.removeCapabilities(withPrefixes: [queryPrefix, modifyPrefix])
        for manifest in AppDictionaryStore.shared.dictionaries.values {
            guard !manifest.classes.isEmpty else { continue }
            // The adapter rung already serves this app — Mail, Messages, Music, Safari,
            // Finder all do — so the dictionary stays out of its way (plan §2c).
            let adapterServesApp = registry.capabilities(for: manifest.bundleID)
                .contains { $0.appBundleID == manifest.bundleID }
            guard !adapterServesApp else { continue }
            registerQuery(manifest, in: registry)
            registerModify(manifest, in: registry)
        }
    }

    private static func registerQuery(
        _ manifest: AppScriptingDictionary, in registry: CapabilityRegistry
    ) {
        let id = queryPrefix + manifest.bundleID
        let app = manifest.appName.isEmpty ? manifest.bundleID : manifest.appName
        let classList = manifest.classes.map(\.name).sorted().prefix(12)
            .joined(separator: ", ")
        registry.register(
            AICapability(
                id: id,
                title: "Read \(app) through its scripting dictionary",
                appBundleID: manifest.bundleID,
                inputSchema: .init(fields: [
                    .init(name: "class", description: "Scripting class to read (e.g. \(classList))", required: true),
                    .init(name: "properties", description: "Comma-separated properties (default: id, name)", required: false),
                    .init(name: "filterProperty", description: "Property to filter by (optional)", required: false),
                    .init(name: "filterOperator", description: "is / is not / contains / begins with / ends with / is greater than / is less than", required: false),
                    .init(name: "filterValue", description: "Value the filter matches", required: false),
                    .init(name: "count", description: "\"true\" to return only a count", required: false),
                    .init(name: "limit", description: "Max rows (default 25)", required: false),
                    .init(name: "root", description: "Read one item the app names instead of the whole class (e.g. \"current track\" for Spotify), paired with class track", required: false),
                ]),
                riskLevel: .low,
                // The rung executes itself (osascript), not through an app adapter — and
                // Spotify/Things-style apps have no adapter at all. Without this flag the
                // tool-less chat path (GeneralChatCapabilityHub) filters the pair out for
                // exactly the apps the rung exists for.
                runsWithoutAdapter: true,
                needsRunningApp: true
            ) { request in
                try await executeQuery(manifest, request: request)
            })
    }

    private static func registerModify(
        _ manifest: AppScriptingDictionary, in registry: CapabilityRegistry
    ) {
        let id = modifyPrefix + manifest.bundleID
        let app = manifest.appName.isEmpty ? manifest.bundleID : manifest.appName
        registry.register(
            AICapability(
                id: id,
                title: "Change \(app) through its scripting dictionary (asks each time)",
                appBundleID: manifest.bundleID,
                inputSchema: .init(fields: [
                    .init(name: "verb", description: "set / make / delete / command (run a learned command such as pause or play; asks first)", required: true),
                    .init(name: "class", description: "Scripting class", required: true),
                    .init(name: "filterProperty", description: "Property to select the target item(s)", required: false),
                    .init(name: "filterOperator", description: "is / contains / … (default is)", required: false),
                    .init(name: "filterValue", description: "Value the filter matches", required: false),
                    // `set`: the property to change; `make`: "k=v" pairs.
                    .init(name: "property", description: "set: the property; make: k=v pairs", required: false),
                    .init(name: "value", description: "set: the new value; make: values inside k=v pairs; command: a text argument", required: false),
                    .init(name: "command", description: "verb command: the learned command's name (pause, play, next track…)", required: false),
                ]),
                riskLevel: .medium,   // every write asks (AGENTS.md)
                runsWithoutAdapter: true,
                needsRunningApp: true
            ) { request in
                try await executeModify(manifest, request: request)
            })
    }

    // MARK: Executors

    private static func executeQuery(
        _ manifest: AppScriptingDictionary, request: AICapabilityExecutionRequest
    ) async throws -> AICapabilityExecutionResult {
        let dictionary = AppDictionaryStore.shared.dictionary(forBundleID: manifest.bundleID)
        guard let dictionary else {
            throw AICapabilityError.blocked(
                DictionaryQueryError.noDictionary(manifest.bundleID).errorDescription ?? "")
        }
        let countOnly = (request.input["count"] ?? "").lowercased() == "true"

        let verb: DictionaryRequest.Verb = countOnly ? .count : .query
        let textRequest = DictionaryRequest(
            verb: verb,
            className: request.input["class"] ?? "",
            propertiesRaw: request.input["properties"] ?? "",
            filterProperty: request.input["filterProperty"] ?? "",
            filterOperator: request.input["filterOperator"].map { $0.isEmpty ? "is" : $0 } ?? "is",
            filterValue: request.input["filterValue"] ?? "",
            limit: Int(request.input["limit"] ?? "25") ?? 25,
            root: request.input["root"] ?? "")
        let script: String
        do {
            script = try AppDictionaryQuery.render(textRequest, for: dictionary)
        } catch let error as DictionaryQueryError {
            // The typed refusal says exactly what to fix, so a corrected second try is
            // possible instead of the model deciding the rung is broken.
            throw AICapabilityError.blocked(error.errorDescription ?? "Could not render the read.")
        }

        let output = try await AppDictionaryExecutor.runAppleScript(script, appName: manifest.appName)
        guard output.success else {
            // "every track doesn't understand the count message" is the app saying it has
            // no such collection — Spotify's shape, where the only track is
            // `current track`. Name the fix instead of returning the AppleScript verbatim.
            return .init(success: false, output: Self.collectionHint(output.text, for: textRequest))
        }
        if countOnly {
            let count = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = textRequest.className
            return .init(
                success: true,
                output: count.isEmpty ? "Count could not be read." : "\(count) \(target)s matched.",
                laneSteps: [laneStep(manifest, action: "Read")])
        }
        let rows = AppDictionaryQuery.parseRows(
            output.text, propertyCount: DictionaryRequest.propertyNames(from: textRequest.propertiesRaw).count)
        recordRows(rows, manifest: manifest, scope: request.chatScope)
        let summary = AppDictionaryQuery.answerLine(for: rows, className: textRequest.className)
        return .init(success: true, output: summary, laneSteps: [laneStep(manifest, action: "Read")])
    }

    private static func executeModify(
        _ manifest: AppScriptingDictionary, request: AICapabilityExecutionRequest
    ) async throws -> AICapabilityExecutionResult {
        let dictionary = AppDictionaryStore.shared.dictionary(forBundleID: manifest.bundleID)
        guard let dictionary else {
            throw AICapabilityError.blocked(
                DictionaryQueryError.noDictionary(manifest.bundleID).errorDescription ?? "")
        }
        let verbRaw = (request.input["verb"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard let verb = DictionaryRequest.Verb(
            rawValue: verbRaw), verb != .query, verb != .count
        else {
            throw AICapabilityError.blocked(
                "Modify needs verb = set, make, delete or command — reads go through dict.query.")
        }
        let textRequest = DictionaryRequest(
            verb: verb,
            className: request.input["class"] ?? "",
            propertiesRaw: verb == .command
                ? (request.input["command"] ?? "") : (request.input["property"] ?? ""),
            value: request.input["value"] ?? "",
            filterProperty: request.input["filterProperty"] ?? "",
            filterOperator: request.input["filterOperator"].map { $0.isEmpty ? "is" : $0 } ?? "is",
            filterValue: request.input["filterValue"] ?? "")
        let script: String
        do {
            script = try AppDictionaryQuery.render(textRequest, for: dictionary)
        } catch let error as DictionaryQueryError {
            throw AICapabilityError.blocked(error.errorDescription ?? "Could not render the change.")
        }

        let outcome = try await AppDictionaryExecutor.runAppleScript(script, appName: manifest.appName)
        let verbWord: String
        let objectWord: String
        switch verb {
        case .set:
            verbWord = "Changed"
            objectWord = textRequest.className + " in " + manifest.appName
        case .make:
            verbWord = "Created"
            objectWord = textRequest.className + " in " + manifest.appName
        case .delete:
            verbWord = "Deleted"
            objectWord = textRequest.className + " in " + manifest.appName
        case .command:
            verbWord = "Ran"
            objectWord = "\"\(textRequest.propertiesRaw)\" in " + manifest.appName
        default:
            verbWord = "Ran"
            objectWord = manifest.appName
        }
        return .init(
            success: outcome.success,
            output: outcome.success
                ? "\(verbWord) \(objectWord)"
                    + "\(outcome.text.isEmpty ? "" : " — \(outcome.text)")"
                : outcome.text,
            laneSteps: [laneStep(manifest, action: verbWord)])
    }

    /// The visible step for the rung — the sentence the hand check reads for: the app
    /// answered with no window opened and no focus moved.
    private static func laneStep(_ manifest: AppScriptingDictionary, action: String) -> String {
        "\(action) via \(manifest.appName)'s scripting dictionary — no window opened"
    }

    /// When the app refuses the collection, say what to try instead. Matched on the
    /// phrasings an app uses for "this is not a collection of mine"; every other failure
    /// is returned untouched.
    nonisolated static func collectionHint(
        _ text: String, for request: DictionaryRequest
    ) -> String {
        let lower = text.lowercased()
        let refused =
            lower.contains("doesn’t understand the") || lower.contains("doesn't understand the")
            || lower.contains("can’t get every") || lower.contains("can't get every")
        guard refused else { return text }
        return text + " — \(request.className) is not a collection in this app's dictionary. "
            + "Read one item the app names instead: set root to a learned "
            + "\(request.className) property (Spotify: root \"current track\", class track)."
    }

    private static func recordRows(
        _ rows: [DictionaryQueryRow], manifest: AppScriptingDictionary,
        scope: GeneralChatScope?
    ) {
        guard !rows.isEmpty else { return }
        let appRows = rows.prefix(24).enumerated().map { index, row -> ChatResultRow in
            let fields = AppDictionaryQuery.rowFields(row)
            return ChatResultRow(
                kind: .note,
                id: "\(manifest.bundleID)#\(index)#\(fields.title)",
                title: fields.title.isEmpty ? manifest.appName : fields.title,
                subtitle: fields.subtitle,
                detail: fields.detail,
                bundleID: manifest.bundleID)
        }
        ChatResultRowCollector.shared.add(appRows, scope: scope)
    }
}

// MARK: - Execution

/// Runs the rendered script. Off-main through `osascript` with a hard watchdog and
/// drained pipes — the pattern AppleNotesExecutionService proved against hung scripts
/// and oversized output. Never called on the main thread synchronously.
enum AppDictionaryExecutor {

    private static let timeout: TimeInterval = 20

    struct Outcome {
        let success: Bool
        let text: String
    }

    static func runAppleScript(_ script: String, appName: String) async throws -> Outcome {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("dict_rung_\(UUID().uuidString).applescript")
            do {
                try script.write(to: tempURL, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = [tempURL.path]
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                try process.run()
                // Hard timeout: a hung Apple Event must never leave the turn spinning.
                var timedOut = false
                let killer = DispatchWorkItem {
                    if process.isRunning {
                        timedOut = true
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                // Drain while running: output past the pipe buffer deadlocks otherwise.
                var outData = Data()
                var errData = Data()
                let drains = DispatchGroup()
                drains.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    drains.leave()
                }
                drains.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    drains.leave()
                }
                process.waitUntilExit()
                drains.wait()
                killer.cancel()
                let text = (String(data: outData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let err = (String(data: errData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if timedOut {
                    continuation.resume(returning: Outcome(
                        success: false,
                        text: "\(appName) did not answer within \(Int(timeout)) s. "
                            + "It may be busy — try again, or nothing at all if it is hung."))
                } else if process.terminationStatus == 0 {
                    continuation.resume(returning: Outcome(success: true, text: text))
                } else {
                    continuation.resume(returning: Outcome(
                        success: false,
                        text: err.isEmpty
                            ? (text.isEmpty ? "The scripting read failed." : text) : err))
                }
            } catch {
                continuation.resume(returning: Outcome(
                    success: false, text: error.localizedDescription))
            }
            }
        }
    }
}

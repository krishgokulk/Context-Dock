// AppDictionaryCapabilities.swift
// Context-Dock
//
// The dictionary rung's executable capabilities, one set per learned scripting app:
//   dict.query.<bundleID>              typed reads (low: runs at once)
//   dict.modify.<bundleID>             typed set/make/delete (medium: the gate card)
//   dict.command.<bundleID>.<slug>     one capability per learned command (read low, write medium)
//   dict.outbound.<bundleID>.<slug>    a command that sends — high risk, always gated
//
// Registration is grant-gated. A manifest is learned by scanning (discovery), but its
// capabilities become executable only for an app the user has brought into this turn: the
// app scope of an App Chat, or an app enabled for a General Chat. Scanning an installed app
// is not consent, so `activeGrants` starts empty and `refreshBuiltInMCPs(dictionaryGrants:)`
// is what changes it. An app DoraX already serves through a built-in adapter keeps that
// adapter and gets no dictionary capability (plan §2c day-one table).
//
// Every write and command reads the app's state back before claiming success, and the
// result carries `readBack` only when the executor actually observed the new value.

import AppKit
import Foundation

extension Notification.Name {
    /// A learned dictionary or its registered capabilities changed. The scope panel reads
    /// the manifest directly, so it must be told when a scan lands mid-session.
    static let appDictionaryChanged = Notification.Name("appDictionaryChanged")
}

@MainActor
enum AppDictionaryCapabilities {

    private static let queryPrefix = "dict.query."
    private static let modifyPrefix = "dict.modify."
    private static let commandPrefix = "dict.command."
    private static let outboundPrefix = "dict.outbound."
    /// Every capability this rung owns. Used by contract tests that must tell a learned
    /// dictionary route apart from an adapter's own typed write.
    static let idPrefix = "dict."

    /// Bundle ids the current turn has granted. Set by the per-turn preflight; empty until
    /// the user scopes a chat to an app. A scan alone never adds to this.
    private(set) static var activeGrants: Set<String> = []
    /// The ids registered last time, so the panel is only told when something really moved.
    private static var lastRegisteredIDs: Set<String> = []

    static func setActiveGrants(_ grants: Set<String>) {
        activeGrants = grants
    }

    /// Drop stale registrations and register capabilities for every learned manifest in
    /// `activeGrants`. Called from `CapabilityRegistry.refreshBuiltInMCPs` on every
    /// preflight, so it must be cheap: reads an in-memory map, no subprocess.
    static func registerLearned(in registry: CapabilityRegistry) {
        registry.removeCapabilities(withPrefixes: [
            queryPrefix, modifyPrefix, commandPrefix, outboundPrefix,
        ])
        var registered: Set<String> = []
        for manifest in AppDictionaryStore.shared.dictionaries.values {
            guard activeGrants.contains(manifest.bundleID) else { continue }
            // The adapter rung already serves this app — Mail, Messages, Music, Safari,
            // Finder all do — so the dictionary stays out of its way (plan §2c).
            let adapterServesApp = registry.capabilities(for: manifest.bundleID)
                .contains { $0.appBundleID == manifest.bundleID }
            guard !adapterServesApp else { continue }
            if !manifest.classes.isEmpty {
                if registerQuery(manifest, in: registry) {
                    registered.insert(queryPrefix + manifest.bundleID)
                }
                if registerModify(manifest, in: registry) {
                    registered.insert(modifyPrefix + manifest.bundleID)
                }
            }
            // Commands are their own capabilities and do not need a class collection.
            registered.formUnion(registerCommands(manifest, in: registry))
        }
        if registered != lastRegisteredIDs {
            lastRegisteredIDs = registered
            NotificationCenter.default.post(name: .appDictionaryChanged, object: nil)
        }
    }

    // MARK: Registration

    @discardableResult
    private static func registerQuery(
        _ manifest: AppScriptingDictionary, in registry: CapabilityRegistry
    ) -> Bool {
        let id = queryPrefix + manifest.bundleID
        let app = displayName(manifest)
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
                // The rung executes itself (typed Apple Events), not through an app adapter
                // — and Spotify/Things-style apps have no adapter at all. Without this flag
                // the tool-less chat path filters the pair out for exactly the apps the rung
                // exists for.
                runsWithoutAdapter: true,
                needsRunningApp: true
            ) { request in
                try await executeQuery(manifest, request: request)
            })
        return true
    }

    @discardableResult
    private static func registerModify(
        _ manifest: AppScriptingDictionary, in registry: CapabilityRegistry
    ) -> Bool {
        let hasWritable = manifest.classes.contains { className in
            className.properties.contains { !$0.isReadOnly && $0.code != nil }
        }
        let hasMakeable = manifest.classes.contains { $0.code != nil }
        guard hasWritable || hasMakeable else { return false }
        let id = modifyPrefix + manifest.bundleID
        let app = displayName(manifest)
        registry.register(
            AICapability(
                id: id,
                title: "Change \(app) through its scripting dictionary (asks each time)",
                appBundleID: manifest.bundleID,
                inputSchema: .init(fields: [
                    .init(name: "verb", description: "set / make / delete", required: true),
                    .init(name: "class", description: "Scripting class", required: true),
                    .init(name: "filterProperty", description: "Property to select the target item(s)", required: false),
                    .init(name: "filterOperator", description: "is / contains / … (default is)", required: false),
                    .init(name: "filterValue", description: "Value the filter matches", required: false),
                    // `set`: the property to change; `make`: "k=v" pairs.
                    .init(name: "property", description: "set: the property; make: one or more k=v pairs", required: false),
                    .init(name: "value", description: "set: the new value; make: values inside k=v pairs", required: false),
                ]),
                riskLevel: .medium,   // every write asks (AGENTS.md)
                runsWithoutAdapter: true,
                needsRunningApp: true
            ) { request in
                try await executeModify(manifest, request: request)
            })
        return true
    }

    /// One capability per learned command. The plan §4.2 manifest shape is per capability,
    /// not one collapsed "modify" verb: a command that can be run is listed, named, and
    /// carries its own risk. Outbound commands are represented too — gated, not erased.
    @discardableResult
    private static func registerCommands(
        _ manifest: AppScriptingDictionary, in registry: CapabilityRegistry
    ) -> Set<String> {
        var registered: Set<String> = []
        var usedSlugs: Set<String> = []
        for command in manifest.commands {
            guard command.code != nil, command.eventClass != nil else { continue }
            guard command.parameterNames.isEmpty else { continue }
            if let direct = command.directType, direct.lowercased() != "text" { continue }
            guard let baseSlug = slug(command.name), !baseSlug.isEmpty else { continue }
            var commandSlug = baseSlug
            var suffix = 2
            while usedSlugs.contains(commandSlug) {
                commandSlug = "\(baseSlug)-\(suffix)"
                suffix += 1
            }
            usedSlugs.insert(commandSlug)

            let outbound = command.verbClass == .outbound
            let id = (outbound ? outboundPrefix : commandPrefix)
                + manifest.bundleID + "." + commandSlug
            let app = displayName(manifest)
            let title = commandTitle(command.name, app: app, outbound: outbound)
            let risk: AICapabilityRiskLevel = outbound
                ? .high : (command.verbClass == .read ? .low : .medium)
            var fields: [AICapabilityInputField] = []
            if command.directType != nil {
                fields.append(.init(
                    name: "value",
                    description: "Text argument for \(command.name)",
                    required: false))
            }
            registry.register(
                AICapability(
                    id: id,
                    title: title,
                    appBundleID: manifest.bundleID,
                    inputSchema: .init(fields: fields),
                    riskLevel: risk,
                    runsWithoutAdapter: true,
                    needsRunningApp: true
                ) { request in
                    try await executeCommand(
                        manifest, commandName: command.name, request: request)
                })
            registered.insert(id)
        }
        return registered
    }

    private static func displayName(_ manifest: AppScriptingDictionary) -> String {
        manifest.appName.isEmpty ? manifest.bundleID : manifest.appName
    }

    private static func slug(_ name: String) -> String? {
        let lowered = name.lowercased()
        var output = ""
        var lastWasDash = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                output.append(character)
                lastWasDash = false
            } else if !lastWasDash, !output.isEmpty {
                output.append("-")
                lastWasDash = true
            }
        }
        while output.hasSuffix("-") { output.removeLast() }
        return output.isEmpty ? nil : output
    }

    private static func commandTitle(
        _ name: String, app: String, outbound: Bool
    ) -> String {
        let readable = name.prefix(1).uppercased() + name.dropFirst()
        return outbound
            ? "\(readable) in \(app) — sends, asks first"
            : "\(readable) in \(app)"
    }

    // MARK: Executors

    private static func dictionary(
        for manifest: AppScriptingDictionary
    ) throws -> AppScriptingDictionary {
        guard let current = AppDictionaryStore.shared.dictionary(
            forBundleID: manifest.bundleID)
        else {
            throw AICapabilityError.blocked(
                DictionaryQueryError.noDictionary(manifest.bundleID).errorDescription ?? "")
        }
        return current
    }

    private static func executeQuery(
        _ manifest: AppScriptingDictionary, request: AICapabilityExecutionRequest
    ) async throws -> AICapabilityExecutionResult {
        let dictionary = try dictionary(for: manifest)
        let countOnly = (request.input["count"] ?? "").lowercased() == "true"
        let textRequest = DictionaryRequest(
            verb: countOnly ? .count : .query,
            className: request.input["class"] ?? "",
            propertiesRaw: request.input["properties"] ?? "",
            filterProperty: request.input["filterProperty"] ?? "",
            filterOperator: request.input["filterOperator"].map { $0.isEmpty ? "is" : $0 } ?? "is",
            filterValue: request.input["filterValue"] ?? "",
            limit: Int(request.input["limit"] ?? "25") ?? 25,
            root: request.input["root"] ?? "")

        let plan: DictionaryPlan
        do {
            plan = try AppDictionaryQuery.plan(textRequest, for: dictionary)
        } catch let error as DictionaryQueryError {
            // The typed refusal says exactly what to fix, so a corrected second try is
            // possible instead of the model deciding the rung is broken.
            throw AICapabilityError.blocked(error.errorDescription ?? "Could not plan the read.")
        }

        let outcome = await run(plan, dictionary: dictionary)
        guard outcome.success else {
            return .init(
                success: false,
                output: failureText(outcome.text, request: textRequest, dictionary: dictionary))
        }
        if countOnly {
            return .init(
                success: true, output: outcome.text,
                laneSteps: [laneStep(manifest, action: "Read")])
        }
        recordRows(outcome.rows, manifest: manifest, scope: request.chatScope)
        return .init(
            success: true, output: outcome.text,
            laneSteps: [laneStep(manifest, action: "Read")])
    }

    private static func executeModify(
        _ manifest: AppScriptingDictionary, request: AICapabilityExecutionRequest
    ) async throws -> AICapabilityExecutionResult {
        let dictionary = try dictionary(for: manifest)
        let verbRaw = (request.input["verb"] ?? "").trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard let verb = DictionaryRequest.Verb(rawValue: verbRaw),
            verb == .set || verb == .make || verb == .delete
        else {
            throw AICapabilityError.blocked(
                "Modify needs verb = set, make or delete — reads go through dict.query and "
                    + "learned commands have their own capability.")
        }
        let textRequest = DictionaryRequest(
            verb: verb,
            className: request.input["class"] ?? "",
            propertiesRaw: request.input["property"] ?? "",
            value: request.input["value"] ?? "",
            filterProperty: request.input["filterProperty"] ?? "",
            filterOperator: request.input["filterOperator"].map { $0.isEmpty ? "is" : $0 } ?? "is",
            filterValue: request.input["filterValue"] ?? "")

        let plan: DictionaryPlan
        do {
            plan = try AppDictionaryQuery.plan(textRequest, for: dictionary)
        } catch let error as DictionaryQueryError {
            throw AICapabilityError.blocked(
                error.errorDescription ?? "Could not plan the change.")
        }

        let outcome = await run(plan, dictionary: dictionary)
        let verbWord: String
        switch verb {
        case .set: verbWord = "Changed"
        case .make: verbWord = "Created"
        case .delete: verbWord = "Deleted"
        default: verbWord = "Changed"
        }
        return .init(
            success: outcome.success,
            output: outcome.text,
            readBack: outcome.readBack,
            laneSteps: [laneStep(manifest, action: verbWord)])
    }

    private static func executeCommand(
        _ manifest: AppScriptingDictionary, commandName: String,
        request: AICapabilityExecutionRequest
    ) async throws -> AICapabilityExecutionResult {
        let dictionary = try dictionary(for: manifest)
        guard let command = dictionary.command(named: commandName) else {
            throw AICapabilityError.blocked(
                DictionaryQueryError.unsupportedCommand(
                    commandName, "the app's dictionary no longer declares it.").errorDescription
                    ?? "")
        }
        let plan: DictionaryPlan
        do {
            plan = try AppDictionaryQuery.commandPlan(
                command, value: request.input["value"] ?? "")
        } catch let error as DictionaryQueryError {
            throw AICapabilityError.blocked(
                error.errorDescription ?? "Could not plan the command.")
        }
        let outcome = await run(plan, dictionary: dictionary)
        return .init(
            success: outcome.success,
            output: outcome.text,
            readBack: outcome.readBack,
            laneSteps: [laneStep(manifest, action: "Ran")])
    }

    /// Typed Apple Events block until the app replies, so they run off the main actor.
    private static func run(
        _ plan: DictionaryPlan, dictionary: AppScriptingDictionary
    ) async -> AppDictionaryExecution {
        let events = AppDictionaryEvents(dictionary: dictionary)
        return await Task.detached(priority: .userInitiated) {
            events.execute(plan)
        }.value
    }

    /// The visible step for the rung — the sentence the hand check reads for: the app
    /// answered with no window opened and no focus moved.
    private static func laneStep(_ manifest: AppScriptingDictionary, action: String) -> String {
        "\(action) via \(manifest.appName)'s scripting dictionary — no window opened"
    }

    /// When an app refuses a collection, say what to try instead. Spotify's shape is the
    /// common one: a single `current track` property and no `every track` collection.
    nonisolated static func failureText(
        _ text: String, request: DictionaryRequest, dictionary: AppScriptingDictionary
    ) -> String {
        let lower = text.lowercased()
        let refused =
            lower.contains("could not find that object") || lower.contains("does not handle")
            || lower.contains("doesn’t understand") || lower.contains("doesn't understand")
            || lower.contains("can’t get every") || lower.contains("can't get every")
        guard refused, request.root.isEmpty, request.verb == .query else { return text }
        let roots = dictionary.classes
            .flatMap(\.properties)
            .filter { $0.type.lowercased() == request.className.lowercased() }
        guard let root = roots.first else { return text }
        return text + " — \(request.className) is not a collection in this app's dictionary. "
            + "Read one item the app names instead: set root to \"\(root.name)\" with class "
            + request.className + "."
    }

    /// Kept for the rung's contract tests, which name the hint's behaviour directly.
    nonisolated static func collectionHint(
        _ text: String, for request: DictionaryRequest
    ) -> String {
        failureText(text, request: request, dictionary: AppScriptingDictionary(
            bundleID: "", appName: "", version: "", parsedAt: Date(),
            classes: [], commands: []))
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

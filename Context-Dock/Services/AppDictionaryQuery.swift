// AppDictionaryQuery.swift
// Context-Dock
//
// The typed request the dictionary rung validates — and the plan it turns into. The model
// never hands over AppleScript; it names a class, properties and a filter, and every
// identifier is checked against the app's own learned manifest before a single Apple Event
// is built. Anything unknown is refused here, with a sentence naming what to fix.
//
// A plan is data, not text: `AppDictionaryEvents` turns it into typed Apple Event
// descriptors (`NSAppleEventDescriptor`) and sends them straight to the app. Nothing is
// rendered into a script, and no `osascript` process exists in this rung.

import Foundation

/// Why a typed request was refused. Every case names what was unknown or missing, so the
/// model can correct itself instead of deciding the rung is broken.
enum DictionaryQueryError: LocalizedError, Equatable {
    case noDictionary(String)
    case unknownClass(String, [String])
    case unknownProperty(String, String, [String])
    case unknownFilterProperty(String, String, [String])
    case unsupportedOperator(String, [String])
    case writeWithoutTarget(String)
    case unsupportedCommand(String, String)
    case unknownRoot(String, String, [String])
    case rootOnlyForReads(String)
    /// The app's sdef declares the term but gave it no four-character code, so a typed
    /// Apple Event cannot address it. Re-scanning does not help; the app itself omitted it.
    case missingCode(String)

    var errorDescription: String? {
        switch self {
        case .noDictionary(let bundleID):
            return "No scripting dictionary is learned for \(bundleID) yet."
        case .unknownClass(let name, let known):
            return "The scripting dictionary has no class \"\(name)\". Known classes: "
                + (known.sorted().prefix(20).joined(separator: ", "))
        case .unknownProperty(let property, let className, let known):
            return "Class \(className) has no property \"\(property)\". Known properties: "
                + (known.prefix(20).joined(separator: ", "))
        case .unknownFilterProperty(let property, let className, let known):
            return "Cannot filter \(className) by \"\(property)\" — it has no such property."
                + (known.isEmpty ? "" : " Known: " + known.prefix(20).joined(separator: ", "))
        case .unsupportedOperator(let op, let known):
            return "Unsupported filter operator \"\(op)\". Supported: "
                + known.joined(separator: ", ")
        case .writeWithoutTarget(let className):
            return "A \(className) write must say WHICH item: give a filter, or DoraX would "
                + "change every \(className) there is."
        case .unsupportedCommand(let command, let reason):
            return "Cannot run \"\(command)\": \(reason)"
        case .unknownRoot(let root, let className, let known):
            return "\"\(root)\" is not a learned \(className) the app exposes. Roots this "
                + "dictionary allows: " + (known.isEmpty ? "none" : known.joined(separator: ", "))
                + ". Use root only for a single item the app names, or omit it to read the "
                + "class collection."
        case .rootOnlyForReads(let verb):
            return "root selects one item, so it only applies to a read (query). "
                + "\"\(verb)\" needs a class collection and a filter."
        case .missingCode(let term):
            return "\(term) has no four-character code in the app's dictionary, so a typed "
                + "Apple Event cannot address it. Use another learned term that has one."
        }
    }
}

/// What the model asked, before validation. All Strings — `AIActionPlan` carries
/// `[String: String]`.
struct DictionaryRequest: Equatable, Sendable {
    enum Verb: String, Equatable, Sendable {
        case query   // read: get properties of the matching items
        case count   // read: how many matching items
        case set     // write: change a property of the matching items (gated)
        case make    // write: create one item (gated)
        case delete  // write: delete the matching items (gated)
    }

    static let filterOperators = [
        "is", "is not", "contains", "begins with", "ends with", "is greater than",
        "is less than",
    ]

    var verb: Verb
    var className: String
    /// A read: comma-separated property names in one string. `make`: "k=v" pairs.
    /// `set`: exactly one property name.
    var propertiesRaw: String
    /// The `set`/`make` value, typed per the property's learned type.
    var value: String
    var filterProperty: String
    var filterOperator: String
    var filterValue: String
    /// Reads only: the cap (the rung tightens or widens the model's number itself).
    var limit: Int
    /// Reads only: one item the app names, instead of "every <class>". The term must be a
    /// property of a learned class whose type is this class — Spotify's "current track" —
    /// so it is validated against the manifest and never reaches the event as free text.
    var root: String

    init(
        verb: Verb, className: String,
        propertiesRaw: String = "", value: String = "",
        filterProperty: String = "", filterOperator: String = "is",
        filterValue: String = "", limit: Int = 25, root: String = ""
    ) {
        self.verb = verb
        self.className = className
        self.propertiesRaw = propertiesRaw
        self.value = value
        self.filterProperty = filterProperty
        self.filterOperator = filterOperator
        self.filterValue = filterValue
        self.limit = limit
        self.root = root
    }

    /// Parse the property list the model sent — comma-separated names, trimmed.
    static func propertyNames(from raw: String) -> [String] {
        raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// A `whose` test: one learned property, a fixed operator, and the value to compare.
struct DictionaryFilter: Equatable, Sendable {
    enum Comparison: String, CaseIterable, Sendable {
        case isEqual = "is"
        case isNot = "is not"
        case contains
        case beginsWith = "begins with"
        case endsWith = "ends with"
        case greaterThan = "is greater than"
        case lessThan = "is less than"

        static func parse(_ raw: String) -> Comparison? {
            let needle = raw.trimmingCharacters(in: .whitespaces).lowercased()
            return allCases.first { $0.rawValue == needle }
        }
    }

    let property: ScriptingProperty
    let comparison: Comparison
    let value: String

    var operatorText: String { comparison.rawValue }
}

/// Which object the plan addresses.
enum DictionaryTarget: Equatable, Sendable {
    /// The app object itself (`player state` of Spotify) — a singleton, never "every
    /// application".
    case application(ScriptingClass)
    /// One item the app names with a learned property (`current track`).
    case singleItem(className: ScriptingClass, root: ScriptingProperty)
    /// Every item of a class, optionally narrowed by a `whose` test.
    case collection(className: ScriptingClass, filter: DictionaryFilter?)

    var className: ScriptingClass {
        switch self {
        case .application(let value): return value
        case .singleItem(let value, _): return value
        case .collection(let value, _): return value
        }
    }

    var isCollection: Bool {
        if case .collection = self { return true }
        return false
    }
}

struct DictionaryAssignment: Equatable, Sendable {
    let property: ScriptingProperty
    let value: String
}

/// A validated, typed operation. No text, no script — just the pieces an Apple Event is
/// built from.
enum DictionaryPlan: Equatable, Sendable {
    case read(target: DictionaryTarget, properties: [ScriptingProperty], limit: Int)
    case count(target: DictionaryTarget)
    case set(target: DictionaryTarget, property: ScriptingProperty, value: String)
    case make(className: ScriptingClass, assignments: [DictionaryAssignment])
    case delete(target: DictionaryTarget)
    case command(ScriptingCommand, value: String)
}

/// One record a read returned, shaped for result rows and for the answer text.
struct DictionaryQueryRow: Equatable, Sendable {
    let values: [String]
}

enum AppDictionaryQuery {

    /// How many rows a read returns at most, whatever the model asked for.
    static let maximumRows = 25
    /// A write touches at most this many objects per card. A filter that matches more is
    /// refused so the approval the user saw stays the set of objects it named.
    static let maximumWrites = 25
    /// Field separator the answer text uses between a row's values.
    static let fieldSeparator = "|||"

    // MARK: Planning

    /// Validate the request against the manifest and build the one operation it allows.
    static func plan(
        _ request: DictionaryRequest, for dictionary: AppScriptingDictionary
    ) throws -> DictionaryPlan {
        let knownClasses = dictionary.classes.map(\.name)
        guard let targetClass = dictionary.class(named: request.className) else {
            throw DictionaryQueryError.unknownClass(request.className, knownClasses)
        }
        if !request.root.isEmpty, request.verb != .query {
            throw DictionaryQueryError.rootOnlyForReads(request.verb.rawValue)
        }

        switch request.verb {
        case .query:
            if !request.root.isEmpty {
                let root = try validatedRoot(request.root, for: targetClass, in: dictionary)
                let properties = try readableProperties(request, target: targetClass)
                return .read(
                    target: .singleItem(className: targetClass, root: root),
                    properties: properties,
                    limit: 1)
            }
            let properties = try readableProperties(request, target: targetClass)
            if targetClass.name.lowercased() == "application" {
                return .read(
                    target: .application(targetClass), properties: properties, limit: 1)
            }
            let filter = try filter(request, target: targetClass)
            let limit = max(1, min(request.limit, maximumRows))
            return .read(
                target: .collection(className: targetClass, filter: filter),
                properties: properties, limit: limit)

        case .count:
            guard targetClass.name.lowercased() != "application" else {
                throw DictionaryQueryError.unsupportedCommand(
                    "count", "the application object is not a collection.")
            }
            return .count(
                target: .collection(
                    className: targetClass, filter: try filter(request, target: targetClass)))

        case .set:
            let names = DictionaryRequest.propertyNames(from: request.propertiesRaw)
            guard names.count == 1 else {
                throw DictionaryQueryError.unknownProperty(
                    "set expects exactly one property (got \(names.count))",
                    targetClass.name, targetClass.writablePropertyNames)
            }
            guard let property = targetClass.property(named: names[0]), !property.isReadOnly
            else {
                throw DictionaryQueryError.unknownProperty(
                    names[0], targetClass.name, targetClass.writablePropertyNames)
            }
            guard property.code != nil else {
                throw DictionaryQueryError.missingCode(
                    "property \"\(property.name)\" of \(targetClass.name)")
            }
            guard let filter = try requiredFilter(request, target: targetClass) else {
                throw DictionaryQueryError.writeWithoutTarget(targetClass.name)
            }
            return .set(
                target: .collection(className: targetClass, filter: filter),
                property: property, value: request.value)

        case .make:
            guard targetClass.code != nil else {
                throw DictionaryQueryError.missingCode("class \"\(targetClass.name)\"")
            }
            var assignments: [DictionaryAssignment] = []
            for pairRaw in DictionaryRequest.propertyNames(from: request.propertiesRaw) {
                // "k=v" pairs; the first '=' splits them, so a value may contain more.
                guard let separator = pairRaw.firstIndex(of: "=") else {
                    throw DictionaryQueryError.unknownProperty(
                        pairRaw, targetClass.name, targetClass.writablePropertyNames)
                }
                let key = String(pairRaw[pairRaw.startIndex..<separator])
                    .trimmingCharacters(in: .whitespaces)
                let rawValue = String(pairRaw[pairRaw.index(after: separator)...])
                guard let property = targetClass.property(named: key), !property.isReadOnly
                else {
                    throw DictionaryQueryError.unknownProperty(
                        key, targetClass.name, targetClass.writablePropertyNames)
                }
                guard property.code != nil else {
                    throw DictionaryQueryError.missingCode(
                        "property \"\(property.name)\" of \(targetClass.name)")
                }
                assignments.append(DictionaryAssignment(property: property, value: rawValue))
            }
            return .make(className: targetClass, assignments: assignments)

        case .delete:
            guard let filter = try requiredFilter(request, target: targetClass) else {
                throw DictionaryQueryError.writeWithoutTarget(targetClass.name)
            }
            return .delete(target: .collection(className: targetClass, filter: filter))
        }
    }

    /// A per-command capability's plan. The command must carry an event class and id, take
    /// no named parameters, and — when it takes an argument — take text. Anything else is
    /// refused rather than guessed at.
    static func commandPlan(
        _ command: ScriptingCommand, value: String
    ) throws -> DictionaryPlan {
        guard command.code != nil, command.eventClass != nil else {
            throw DictionaryQueryError.missingCode("command \"\(command.name)\"")
        }
        guard command.parameterNames.isEmpty else {
            throw DictionaryQueryError.unsupportedCommand(
                command.name,
                "it takes named parameters (\(command.parameterNames.joined(separator: ", "))), "
                    + "which this rung does not send yet. Use the app itself.")
        }
        if let directType = command.directType {
            guard directType.lowercased() == "text" else {
                throw DictionaryQueryError.unsupportedCommand(
                    command.name,
                    "its argument is \(directType), which this rung does not send yet.")
            }
        } else if !value.isEmpty {
            throw DictionaryQueryError.unsupportedCommand(
                command.name, "it takes no argument.")
        }
        return .command(command, value: value)
    }

    private static func filter(
        _ request: DictionaryRequest, target: ScriptingClass
    ) throws -> DictionaryFilter? {
        let propertyName = request.filterProperty.trimmingCharacters(in: .whitespaces)
        guard !propertyName.isEmpty else { return nil }
        guard let property = target.property(named: propertyName) else {
            throw DictionaryQueryError.unknownFilterProperty(
                propertyName, target.name, target.readablePropertyNames)
        }
        guard property.code != nil else {
            throw DictionaryQueryError.missingCode(
                "filter property \"\(property.name)\" of \(target.name)")
        }
        let operatorText = request.filterOperator.isEmpty ? "is" : request.filterOperator
        guard let comparison = DictionaryFilter.Comparison.parse(operatorText) else {
            throw DictionaryQueryError.unsupportedOperator(
                operatorText, DictionaryRequest.filterOperators)
        }
        return DictionaryFilter(
            property: property, comparison: comparison, value: request.filterValue)
    }

    private static func requiredFilter(
        _ request: DictionaryRequest, target: ScriptingClass
    ) throws -> DictionaryFilter? {
        guard !request.filterProperty.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return try filter(request, target: target)
    }

    /// The properties a read may ask for. A named property must exist, be readable, and
    /// carry a code. Nothing named means the identity defaults: id and name first, then
    /// the remaining readable properties, at most six all told.
    private static func readableProperties(
        _ request: DictionaryRequest, target: ScriptingClass
    ) throws -> [ScriptingProperty] {
        let named = DictionaryRequest.propertyNames(from: request.propertiesRaw)
        if !named.isEmpty {
            var requested: [ScriptingProperty] = []
            for name in named {
                guard let property = target.property(named: name), !property.isWriteOnly else {
                    throw DictionaryQueryError.unknownProperty(
                        name, target.name, target.readablePropertyNames)
                }
                guard property.code != nil else {
                    throw DictionaryQueryError.missingCode(
                        "property \"\(property.name)\" of \(target.name)")
                }
                requested.append(property)
            }
            return requested
        }
        let readable = target.properties.filter { !$0.isWriteOnly && $0.code != nil }
        let identity = readable.filter {
            ["id", "name"].contains($0.name.lowercased())
        }
        let rest = readable
            .filter { property in !identity.contains(where: { $0.name == property.name }) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        let requested = Array((identity + rest).prefix(6))
        guard !requested.isEmpty else {
            throw DictionaryQueryError.missingCode(
                "no readable property of \(target.name)")
        }
        return requested
    }

    /// The learned term that selects one item, or nil when the read wants a collection.
    /// A root is only allowed when it is a property the dictionary declares and that
    /// property's type is the class being read — so `current track` may root a `track`
    /// read, and anything the app never wrote cannot reach the event.
    private static func validatedRoot(
        _ raw: String, for target: ScriptingClass, in dictionary: AppScriptingDictionary
    ) throws -> ScriptingProperty {
        let needle = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let roots = dictionary.classes
            .flatMap(\.properties)
            .filter { $0.type.lowercased() == target.name.lowercased() }
        guard let match = roots.first(where: { $0.name.lowercased() == needle }) else {
            throw DictionaryQueryError.unknownRoot(
                raw, target.name, Array(Set(roots.map(\.name))).sorted())
        }
        guard match.code != nil else {
            throw DictionaryQueryError.missingCode(
                "property \"\(match.name)\" of \(target.name)")
        }
        return match
    }

    // MARK: Output

    /// Convenience for the executor: the first three meaningful values of a row, made
    /// into title / subtitle / detail.
    static func rowFields(_ row: DictionaryQueryRow)
        -> (title: String, subtitle: String, detail: String)
    {
        let meaningful = row.values.filter { !$0.isEmpty }
        return (
            title: meaningful.first ?? "",
            subtitle: meaningful.count > 1 ? meaningful[1] : "",
            detail: meaningful.count > 2 ? meaningful[2] : "")
    }

    /// The text the answer shows — a numbered list, one line per row, title leading.
    /// The model reads this directly; rows travel separately as cards.
    static func answerLine(for rows: [DictionaryQueryRow], className: String) -> String {
        guard !rows.isEmpty else {
            return "No \(className)s matched."
        }
        let lines = rows.prefix(12).enumerated()
            .map { index, row -> String in
                let fields = rowFields(row)
                var text = "  \(index + 1). \(fields.title)"
                if !fields.subtitle.isEmpty { text += " — \(fields.subtitle)" }
                if !fields.detail.isEmpty { text += " (\(fields.detail))" }
                return text
            }
            .joined(separator: "\n")
        let more = rows.count > 12 ? "\n  … and \(rows.count - 12) more." : ""
        return "\(rows.count) \(className)\(rows.count == 1 ? "" : "s") so far:\n" + lines + more
    }
}

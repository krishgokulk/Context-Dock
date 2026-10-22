// AppDictionaryQuery.swift
// Context-Dock
//
// The typed expression the dictionary rung runs. The model never hands over AppleScript;
// it names a class, properties and a filter, and this builder renders the one script the
// app's own manifest allows, validating every identifier against it. Anything unknown is
// refused before a single Apple Event moves — that is what makes this a typed request and
// not a personality injection to `osascript`.
//
// The rendered script is text, so the executor can run it through the same hardened
// subprocess pattern the Notes reader uses (temp file, hard watchdog, drained pipes).
// Values are escaped; identifiers never carry user data because each one must exist in
// the learned manifest first.

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
    case outboundCommand(String)

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
        case .outboundCommand(let command):
            return "\"\(command)\" sends something outside this Mac; the dictionary rung "
                + "never sends. Use the app itself for anything that sends."
        }
    }
}

/// What the model asked, before rendering. All Strings — `AIActionPlan` carries
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
    /// The `make`/`set` value, rendered per the property's learned type.
    var value: String
    var filterProperty: String
    var filterOperator: String
    var filterValue: String
    /// Reads only: the cap (the rung tightens or widens the model's number itself).
    var limit: Int

    init(
        verb: Verb, className: String,
        propertiesRaw: String = "", value: String = "",
        filterProperty: String = "", filterOperator: String = "is",
        filterValue: String = "", limit: Int = 25
    ) {
        self.verb = verb
        self.className = className
        self.propertiesRaw = propertiesRaw
        self.value = value
        self.filterProperty = filterProperty
        self.filterOperator = filterOperator
        self.filterValue = filterValue
        self.limit = limit
    }

    /// Parse the property list the model sent — comma-separated Names, trimmed.
    static func propertyNames(from raw: String) -> [String] {
        raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// One record a read returned, shaped for result rows and for the answer text.
struct DictionaryQueryRow: Equatable, Sendable {
    let values: [String]
}

enum AppDictionaryQuery {

    /// How many rows a read returns at most, whatever the model asked for.
    private static let maximumRows = 25
    /// Field separator in the rendered script's output — the house convention is already
    /// `|||` (AppleAppsAPI's mail reader uses the same).
    static let fieldSeparator = "|||"

    // MARK: Rendering

    /// Validate the request against the manifest and render the one script it allows.
    /// Never sends (the rung's rule): an outbound request is refused upstream, before any
    /// script exists; `set`/`make`/`delete` render fine and go through the gate as cards.
    static func render(_ request: DictionaryRequest, for dictionary: AppScriptingDictionary)
        throws -> String
    {
        let knownClasses = dictionary.classes.map(\.name)
        guard let target = dictionary.class(named: request.className) else {
            throw DictionaryQueryError.unknownClass(request.className, knownClasses)
        }
        switch request.verb {
        case .query: return try renderRead(request, target, dictionary)
        case .count: return try renderCount(request, target, dictionary)
        case .set: return try renderSet(request, target, dictionary)
        case .make: return try renderMake(request, target, dictionary)
        case .delete: return try renderDelete(request, target, dictionary)
        }
    }

    /// The `whose` clause for the request's filter, or "" when none was given. The filter
    /// property must exist on the class and the operator must be from the fixed set; the
    /// value is rendered as a literal typed to the property, so "id is 42" filters on the
    /// number rather than the word.
    private static func whoseClause(_ request: DictionaryRequest, target: ScriptingClass)
        throws -> String
    {
        guard !request.filterProperty.isEmpty else { return "" }
        guard let filterTarget = target.property(named: request.filterProperty) else {
            throw DictionaryQueryError.unknownFilterProperty(
                request.filterProperty, target.name, target.readablePropertyNames)
        }
        let operatorText = request.filterOperator.isEmpty ? "is" : request.filterOperator
        guard DictionaryRequest.filterOperators.contains(operatorText) else {
            throw DictionaryQueryError.unsupportedOperator(
                operatorText, DictionaryRequest.filterOperators)
        }
        return " whose \(request.filterProperty) \(operatorText) "
            + literal(request.filterValue, type: filterTarget.type)
    }

    private static func renderRead(
        _ request: DictionaryRequest,
        _ target: ScriptingClass,
        _ dictionary: AppScriptingDictionary
    ) throws -> String {
        let named = DictionaryRequest.propertyNames(from: request.propertiesRaw)
        var requested: [ScriptingProperty] = []
        if named.isEmpty {
            // Nothing named means the identity defaults: id and name first, then the
            // remaining readable properties, at most six all told.
            let names = target.readablePropertyNames
                .filter { $0.lowercased() == "id" || $0.lowercased() == "name" }
            let rest = target.readablePropertyNames
                .filter { name in !names.contains(name) }
                .sorted { $0.lowercased() < $1.lowercased() }
            requested = (names + rest)
                .compactMap { target.property(named: $0) }
                .prefix(6).map { $0 }
        } else {
            for name in named {
                guard let property = target.property(named: name), !property.isWriteOnly else {
                    throw DictionaryQueryError.unknownProperty(
                        name, target.name, target.readablePropertyNames)
                }
                requested.append(property)
            }
        }
        guard !requested.isEmpty else {
            throw DictionaryQueryError.unknownProperty(
                target.name, target.name, target.readablePropertyNames)
        }
        let whose = try whoseClause(request, target: target)
        let limit = max(1, min(request.limit, maximumRows))

        var lines: [String] = [
            "with timeout of 15 seconds",
            "tell application id \"\(dictionary.bundleID)\"",
            "    set _recs to every \(target.name)\(whose)",
            "    set _out to \"\"",
            "    set _collected to 0",
            "    repeat with _r in _recs",
            "        if _collected >= \(limit) then exit repeat",
        ]
        for (index, property) in requested.enumerated() {
            lines.append("        set _v\(index) to \"\"")
            lines.append("        try")
            lines.append("            set _v\(index) to (\(property.name) of _r) as text")
            lines.append("        end try")
        }
        var line = "        set _line to _v0"
        for index in Array(requested.indices.dropFirst()) {
            line += " & \"\(fieldSeparator)\" & _v\(index)"
        }
        lines.append(line)
        lines.append("        set _collected to _collected + 1")
        lines.append("        set _out to _out & _line & \"\(fieldSeparator)\" & linefeed")
        lines.append("    end repeat")
        lines.append("    return _out")
        lines.append("end tell")
        lines.append("end with timeout")
        return lines.joined(separator: "\n")
    }

    private static func renderCount(
        _ request: DictionaryRequest,
        _ target: ScriptingClass,
        _ dictionary: AppScriptingDictionary
    ) throws -> String {
        let whose = try whoseClause(request, target: target)
        return [
            "with timeout of 15 seconds",
            "tell application id \"\(dictionary.bundleID)\" to count of",
            "    (every \(target.name)\(whose))",
            "end with timeout",
        ].joined(separator: "\n")
    }

    private static func renderSet(
        _ request: DictionaryRequest,
        _ target: ScriptingClass,
        _ dictionary: AppScriptingDictionary
    ) throws -> String {
        let names = DictionaryRequest.propertyNames(from: request.propertiesRaw)
        guard names.count == 1 else {
            throw DictionaryQueryError.unknownProperty(
                "set expects exactly one property (got \(names.count))",
                target.name, target.writablePropertyNames)
        }
        guard let property = target.property(named: names[0]), !property.isReadOnly else {
            throw DictionaryQueryError.unknownProperty(
                names[0], target.name, target.writablePropertyNames)
        }
        let whose = try whoseClause(request, target: target)
        guard !whose.isEmpty else {
            throw DictionaryQueryError.writeWithoutTarget(target.name)
        }
        return [
            "with timeout of 15 seconds",
            "tell application id \"\(dictionary.bundleID)\"",
            "    set \(property.name) of (every \(target.name)\(whose)) to "
                + literal(request.value, type: property.type),
            "end tell",
            "end with timeout",
        ].joined(separator: "\n")
    }

    private static func renderMake(
        _ request: DictionaryRequest,
        _ target: ScriptingClass,
        _ dictionary: AppScriptingDictionary
    ) throws -> String {
        var assignments: [String] = []
        for pairRaw in DictionaryRequest.propertyNames(from: request.propertiesRaw) {
            // "k=v" pairs; the first '=' splits them, so a value may contain more.
            guard let separator = pairRaw.firstIndex(of: "=") else {
                throw DictionaryQueryError.unknownProperty(
                    pairRaw, target.name, target.writablePropertyNames)
            }
            let key = String(pairRaw[pairRaw.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            let rawValue = String(pairRaw[pairRaw.index(after: separator)...])
            guard let property = target.property(named: key), !property.isReadOnly else {
                throw DictionaryQueryError.unknownProperty(
                    key, target.name, target.writablePropertyNames)
            }
            assignments.append("\(key): \(literal(rawValue, type: property.type))")
        }
        let withProperties = assignments.isEmpty
            ? "" : " with properties {\(assignments.joined(separator: ", "))}"
        return [
            "with timeout of 15 seconds",
            "tell application id \"\(dictionary.bundleID)\"",
            "    make new \(target.name)\(withProperties)",
            "end tell",
            "end with timeout",
        ].joined(separator: "\n")
    }

    private static func renderDelete(
        _ request: DictionaryRequest,
        _ target: ScriptingClass,
        _ dictionary: AppScriptingDictionary
    ) throws -> String {
        let whose = try whoseClause(request, target: target)
        guard !whose.isEmpty else {
            throw DictionaryQueryError.writeWithoutTarget(target.name)
        }
        return [
            "with timeout of 15 seconds",
            "tell application id \"\(dictionary.bundleID)\"",
            "    delete (every \(target.name)\(whose))",
            "end tell",
            "end with timeout",
        ].joined(separator: "\n")
    }

    // MARK: Literals

    /// An AppleScript string literal, with the backslash and quote escaped — the one
    /// place a value the model sent reaches the script text.
    static func literal(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// A literal typed to the property's learned type, so an integer arrives as 42 and a
    /// boolean as true — a text-typed "42" against an integer property is how a write
    /// fails the one way that would look like the app's fault.
    static func literal(_ value: String, type: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        switch type.lowercased() {
        case "integer":
            if Int(trimmed) != nil { return trimmed }
        case "real", "number":
            if Double(trimmed) != nil { return trimmed }
        case "boolean", "bool":
            if ["true", "false"].contains(trimmed.lowercased()) {
                return trimmed.lowercased()
            }
        default:
            break
        }
        return literal(trimmed)
    }

    // MARK: Output

    /// Parse the read script's output into rows. Each collected row is
    /// `value ||| value ||| … \u{2026} |||` — a trailing separator always follows a
    /// complete record, so a line without one is either an empty result or a straggler
    /// and both read as no rows.
    static func parseRows(_ output: String, propertyCount: Int) -> [DictionaryQueryRow] {
        var rows: [DictionaryQueryRow] = []
        for line in output.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.contains(fieldSeparator) else { continue }
            var values = text
                .dropLast(fieldSeparator.count)
                .components(separatedBy: fieldSeparator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if propertyCount > 0 {
                while values.count < propertyCount { values.append("") }
                values = Array(values.prefix(propertyCount))
            }
            // A record whose every field failed to read is not a record.
            guard values.contains(where: { !$0.isEmpty }) else { continue }
            rows.append(DictionaryQueryRow(values: values))
            if rows.count >= maximumRows { break }
        }
        return rows
    }

    /// Convenience for the executor: the first three meaningful values of a row, made
    /// into title / subtitle / detail.
    static func rowFields(_ row: DictionaryQueryRow) -> (title: String, subtitle: String, detail: String) {
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

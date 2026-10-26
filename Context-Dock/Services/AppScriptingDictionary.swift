// AppScriptingDictionary.swift
// Context-Dock
//
// The scripting-dictionary rung of the data lane (P13 #208, plan §4.1 "AppleScript
// dictionary"): read any scriptable app without a hand-written adapter. Third-party
// scriptable apps (Spotify, Things, Office, BBEdit…) had no data route at all today,
// so their chats fell straight to menus and the screen.
//
// What this file does:
//   • parses the app's own `sdef` output into a small learned manifest
//     (classes, properties, elements, commands);
//   • classifies every command read / write / outbound — the same gate classes the
//     CLI learner uses (`CLIVerbClassifier`), so "writes and sends always ask" holds
//     here too without a second classification vocabulary.
//
// The model never writes AppleScript in this rung. It names a class, properties and a
// filter; `AppDictionaryQuery` builds the script from those validated pieces, and every
// identifier must come from this manifest. No free-form text reaches the app.
//
// Pure and static where possible, like the CLI learner's classifier: the tests must run
// without a Mac, a live app or an Apple Event.

import Foundation

// MARK: - Learned manifest

/// What one scripting property is, as learned from the app's sdef.
struct ScriptingProperty: Codable, Equatable, Sendable {
    let name: String
    /// The sdef type name: "text", "integer", "boolean", "date", or the name of another
    /// class. The query builder uses it to pick a literal.
    let type: String
    let isReadOnly: Bool
    let isWriteOnly: Bool
    /// The sdef description, capped — it goes into nothing per-turn, but the manifest
    /// should stay small on disk.
    let summary: String
    /// The property's four-character sdef code ('pnam'). A typed Apple Event addresses a
    /// property by this code, so a property without one cannot be read or written by the
    /// rung and is left out of the readable/writable lists below.
    var code: String? = nil
}

/// One value an enumeration can take, with the four-character code the app sends.
struct ScriptingEnumerationCase: Codable, Equatable, Sendable {
    let name: String
    let code: String
}

/// An sdef enumeration (`player state` is stopped/playing/paused). Read replies carry the
/// code; the name is what the user and the model read.
struct ScriptingEnumeration: Codable, Equatable, Sendable {
    let name: String
    let code: String
    var cases: [ScriptingEnumerationCase]

    func name(forCode code: String) -> String? {
        cases.first { $0.code == code }?.name
    }
}

/// What one scripting class is, plus the properties and contained classes it declares.
struct ScriptingClass: Codable, Equatable, Sendable {
    let name: String
    /// The suite the declaration came from, so an app-specific class wins over the
    /// Standard Suite's stub when both declare the same name.
    let suite: String
    var plural: String
    var properties: [ScriptingProperty]
    /// Classes this one contains (`to recipient` inside a message) — the accessor fields
    /// available on this class in a `whose` read.
    var elementTypes: [String]
    /// Commands this class answers for, from `<responds-to>`.
    var respondsTo: [String]
    /// The class's four-character sdef code ('mssg').
    var code: String? = nil

    func property(named: String) -> ScriptingProperty? {
        let needle = named.lowercased()
        return properties.first { $0.name.lowercased() == needle }
    }

    /// Properties a read may ask for. A write-only property has no reading.
    var readablePropertyNames: [String] {
        properties.filter { !$0.isWriteOnly }.map(\.name)
    }

    var writablePropertyNames: [String] {
        properties.filter { !$0.isReadOnly }.map(\.name)
    }
}

/// One command parameter, as declared in the sdef.
struct ScriptingParameter: Codable, Equatable, Sendable {
    let name: String
    let type: String
    var code: String? = nil
}

/// What one scripting command is, already classified for the gate.
struct ScriptingCommand: Codable, Equatable, Sendable {
    let name: String
    let suite: String
    /// read / write / outbound, per `CLIVerbClass`.
    let verbClass: CLIVerbClass
    /// The type of the direct parameter, when the command takes one.
    let directType: String?
    var parameters: [ScriptingParameter] = []
    /// The command's four-character event id ('Paus'), and the event class it is sent to
    /// ('spfy'). sdef often prints both together in `code` ("spfyPaus"); the parser splits
    /// that into these two fields.
    var code: String? = nil
    var eventClass: String? = nil

    var parameterNames: [String] { parameters.map(\.name) }
}

extension ScriptingCommand {
    /// Old manifests (schema 0/1) have no `parameters`/`code`/`eventClass`; they must still
    /// decode, because the store compares the schema to decide whether to re-scan.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        suite = try container.decode(String.self, forKey: .suite)
        verbClass = try container.decode(CLIVerbClass.self, forKey: .verbClass)
        directType = try container.decodeIfPresent(String.self, forKey: .directType)
        parameters = try container.decodeIfPresent(
            [ScriptingParameter].self, forKey: .parameters) ?? []
        code = try container.decodeIfPresent(String.self, forKey: .code)
        eventClass = try container.decodeIfPresent(String.self, forKey: .eventClass)
    }
}

/// A whole app's learned scripting manifest.
struct AppScriptingDictionary: Codable, Equatable, Sendable {
    /// Bumped whenever the manifest gains a field a stored copy may not have (codes,
    /// enumerations). A cached manifest below this is re-scanned rather than used, so the
    /// typed executor never meets half a manifest.
    static let currentSchema = 2

    let bundleID: String
    let appName: String
    /// The app version the manifest was scanned from. A version change is what makes
    /// `AppDictionaryStore` scan again.
    let version: String
    var parsedAt: Date
    var classes: [ScriptingClass]
    var commands: [ScriptingCommand]
    var enumerations: [ScriptingEnumeration] = []
    var schema: Int = AppScriptingDictionary.currentSchema

    var isEmpty: Bool { classes.isEmpty && commands.isEmpty }

    func `class`(named: String) -> ScriptingClass? {
        let needle = named.lowercased()
        // An app's own suite is the better answer for a name both it and the Standard
        // Suite declare ("application"): it carries the app's properties and elements.
        return classes.first { $0.name.lowercased() == needle && $0.suite != "Standard Suite" }
            ?? classes.first { $0.name.lowercased() == needle }
    }

    func command(named: String) -> ScriptingCommand? {
        let needle = named.lowercased()
        return commands.first { $0.name.lowercased() == needle }
    }

    /// One line for a learned-tool summary: which classes the rung can now read.
    var summarySentence: String {
        let classCount = classes.count
        let readable = classes.map(\.name).sorted().prefix(8).joined(separator: ", ")
        let writes = commands.filter { $0.verbClass != .read }.count
        return "Learned \(classCount) scripting class\(classCount == 1 ? "" : "es")"
            + (readable.isEmpty ? "" : " (\(readable))")
            + " and \(commands.count) command\(commands.count == 1 ? "" : "s") — "
            + "\(writes) are writes that ask first."
    }
}

extension AppScriptingDictionary {
    /// `schema`/`enumerations` are newer than the first stored manifests; a missing schema
    /// decodes as 0, which the store treats as stale and re-scans.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        appName = try container.decode(String.self, forKey: .appName)
        version = try container.decode(String.self, forKey: .version)
        parsedAt = try container.decode(Date.self, forKey: .parsedAt)
        classes = try container.decode([ScriptingClass].self, forKey: .classes)
        commands = try container.decode([ScriptingCommand].self, forKey: .commands)
        enumerations = try container.decodeIfPresent(
            [ScriptingEnumeration].self, forKey: .enumerations) ?? []
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? 0
    }
}

// MARK: - Command classification

/// Classifies a dictionary command for the gate. Reuses `CLIVerbClassifier`'s verb sets
/// — read / write / outbound are one vocabulary for CLIs and Apple Events both — and adds
/// the Apple-specific verbs the CLI list has no word for (`make`, `duplicate`, `play`…).
/// Unknown stays a write: unknown asks (§6.1 rule), never reads.
enum AppDictionaryCommandClassifier {

    /// Apple verbs with no CLI counterpart. set/delete/move/send etc. come from the
    /// shared lists.
    private static let appleWriteVerbs: Set<String> = [
        "make", "duplicate", "open", "close", "save", "launch", "quit", "activate",
        "play", "pause", "stop", "resume", "synchronize", "eject", "convert",
        "import", "download", "toggle", "skip", "step", "export", "playpause",
        "next", "previous",
    ]
    private static let appleReadVerbs: Set<String> = [
        "extract", "exists", "query",
    ]
    /// Anything that sends something to another person or service — a write that is also
    /// outbound. `redirect` (Mail) creates a re-addressed message and counts no better.
    private static let appleOutboundVerbs: Set<String> = [
        "redirect", "transmit", "publish", "share", "post", "upload",
    ]

    static func verbClass(ofCommandName name: String) -> CLIVerbClass? {
        let tokens = name
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
        guard !tokens.isEmpty else { return nil }

        // Multi-word names ("check for new mail", "extract name from"): a send anywhere
        // is outbound, a write anywhere is a write; only then does a read count.
        for token in tokens {
            if CLIVerbClassifier.outboundVerbs.contains(token) { return .outbound }
            if appleOutboundVerbs.contains(token) { return .outbound }
        }
        for token in tokens {
            if CLIVerbClassifier.writeVerbs.contains(token) { return .write }
            if appleWriteVerbs.contains(token) { return .write }
        }
        for token in tokens {
            if CLIVerbClassifier.readVerbs.contains(token) { return .read }
            if appleReadVerbs.contains(token) { return .read }
        }
        // Compounds ("playpause", "next-track"): only a destructive or sending part counts.
        for token in tokens {
            if let compound = compoundClass(ofToken: token) { return compound }
        }
        return nil
    }

    private static func compoundClass(ofToken token: String) -> CLIVerbClass? {
        let parts = token.split(separator: "-").map(String.init)
        guard parts.count > 1 else { return nil }
        for part in parts {
            if CLIVerbClassifier.outboundVerbs.contains(part) { return .outbound }
            if appleOutboundVerbs.contains(part) { return .outbound }
        }
        for part in parts {
            if CLIVerbClassifier.writeVerbs.contains(part) { return .write }
            if appleWriteVerbs.contains(part) { return .write }
        }
        return nil
    }
}

// MARK: - sdef parser

/// Parses the XML an app's `sdef` prints into the manifest above. Tolerant: an app that
/// nests types oddly or declares a command twice still yields a manifest this rung can
/// use, and anything hidden or unshapable is simply dropped.
enum AppSdefParser {

    /// Parse recorded sdef XML. `bundleID`/`appName`/`version` stamp the manifest; the
    /// XML itself names none of them.
    static func parse(
        _ xml: String, bundleID: String, appName: String, version: String
    ) -> AppScriptingDictionary {
        let delegate = Delegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()

        var classes = delegate.collectedClasses
        // A class-extension adds elements to an existing class (Mail extends the Standard
        // application). Applied where the class exists; kept as its own entry otherwise.
        for extensionItem in delegate.collectedExtensions {
            if let index = classes.firstIndex(where: {
                $0.name.lowercased() == extensionItem.name.lowercased()
            }) {
                let existing = classes[index].elementTypes
                classes[index].elementTypes = existing + extensionItem.elementTypes
            } else {
                classes.append(extensionItem)
            }
        }

        let commands = delegate.collectedCommands.map { raw in
            ScriptingCommand(
                name: raw.name, suite: raw.suite,
                // Unknown asks, never reads — the safe default (CLIVerbClassifier rule).
                verbClass: AppDictionaryCommandClassifier.verbClass(ofCommandName: raw.name)
                    ?? .write,
                directType: raw.directType,
                parameters: raw.parameters,
                code: raw.eventID,
                eventClass: raw.eventClass)
        }

        return AppScriptingDictionary(
            bundleID: bundleID, appName: appName, version: version,
            parsedAt: Date(), classes: classes, commands: commands,
            enumerations: delegate.collectedEnumerations,
            schema: AppScriptingDictionary.currentSchema)
    }

    // MARK: XML delegate

    private final class Delegate: NSObject, XMLParserDelegate {

        /// What is currently being read, so `hidden` on a wrapping element drops the
        /// property inside it.
        private struct PendingProperty {
            let name: String
            let code: String?
            let access: String
            let description: String
            var hidden: Bool
            var nestedTypes: [String]
        }

        private struct PendingEnumeration {
            let name: String
            let code: String
            var cases: [ScriptingEnumerationCase] = []
        }

        private var suiteName = ""
        private var suiteCode = ""
        private var pendingClass: ScriptingClassBuilder?
        private var pendingCommand: ScriptingCommandBuilder?
        private var pendingProperty: PendingProperty?
        private var pendingEnumeration: PendingEnumeration?

        var collectedClasses: [ScriptingClass] = []
        var collectedExtensions: [ScriptingClass] = []
        var collectedEnumerations: [ScriptingEnumeration] = []
        var collectedCommands: [(
            name: String, suite: String, hidden: Bool, directType: String?,
            eventClass: String?, eventID: String?, parameters: [ScriptingParameter]
        )] = []

        private func trim(_ raw: String?) -> String {
            (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func summary(_ raw: String?) -> String {
            String((raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let hidden = (attributeDict["hidden"] ?? "").lowercased() == "yes"
            switch elementName {
            case "suite":
                suiteName = trim(attributeDict["name"])
                suiteCode = trim(attributeDict["code"])
            case "enumeration":
                pendingEnumeration = PendingEnumeration(
                    name: trim(attributeDict["name"]), code: trim(attributeDict["code"]))
            case "enumerator":
                if let name = attributeDict["name"], let code = attributeDict["code"],
                    !trim(name).isEmpty, !trim(code).isEmpty
                {
                    pendingEnumeration?.cases.append(
                        ScriptingEnumerationCase(name: trim(name), code: trim(code)))
                }
            case "class":
                pendingClass = ScriptingClassBuilder(
                    name: trim(attributeDict["name"]), suite: suiteName,
                    code: trim(attributeDict["code"]),
                    plural: trim(attributeDict["plural"]).isEmpty
                        ? trim(attributeDict["name"]) : trim(attributeDict["plural"]),
                    hidden: hidden)
            case "class-extension":
                // Extends the Standard application; the merge pass below applies it.
                pendingClass = ScriptingClassBuilder(
                    name: trim(attributeDict["extends"]), suite: suiteName,
                    code: trim(attributeDict["code"]),
                    plural: trim(attributeDict["extends"]), hidden: hidden, isExtension: true)
            case "command", "event", "application-command":
                pendingCommand = ScriptingCommandBuilder(
                    name: trim(attributeDict["name"]), suite: suiteName,
                    code: trim(attributeDict["code"]), suiteCode: suiteCode, hidden: hidden)
            case "responds-to":
                if let target = trim(attributeDict["command"]).isEmpty ? nil : attributeDict["command"] {
                    pendingClass?.respondsTo.append(target)
                }
            case "property":
                pendingProperty = PendingProperty(
                    name: trim(attributeDict["name"]),
                    code: trim(attributeDict["code"]).isEmpty ? nil : trim(attributeDict["code"]),
                    access: trim(attributeDict["access"]),
                    description: summary(attributeDict["description"]),
                    hidden: hidden,
                    nestedTypes: [])
                pendingProperty?.nestedTypes.append(trim(attributeDict["type"]))
            case "element":
                guard !hidden else { break }
                let type = trim(attributeDict["type"])
                guard !type.isEmpty else { break }
                pendingClass?.elementTypes.append(type)
            case "direct-parameter":
                pendingCommand?.directType =
                    trim(attributeDict["type"]).isEmpty
                    ? nil : trim(attributeDict["type"])
                pendingCommand?.nestedDirectTypeCounter += 1
            case "parameter":
                if !hidden {
                    let name = trim(attributeDict["name"])
                    let type = trim(attributeDict["type"])
                    let code = trim(attributeDict["code"])
                    if !name.isEmpty {
                        pendingCommand?.parameters.append(
                            ScriptingParameter(
                                name: name, type: type.lowercased(),
                                code: code.isEmpty ? nil : code))
                    }
                }
            case "type":
                // Nested: `<type type="signature"/>` in a property, or
                // `<type name="document">{{…}}</type>` in a parameter.
                if let nestedType = attributeDict["type"], !nestedType.isEmpty {
                    pendingProperty?.nestedTypes.append(nestedType)
                } else if let nestedName = attributeDict["name"], !nestedName.isEmpty,
                    pendingCommand?.directType == nil
                {
                    pendingCommand?.nestedDirectTypeName = nestedName
                }
            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            switch elementName {
            case "suite":
                suiteName = ""
                suiteCode = ""
            case "enumeration":
                if let finished = pendingEnumeration, !finished.name.isEmpty,
                    !finished.code.isEmpty, !finished.cases.isEmpty
                {
                    collectedEnumerations.append(
                        ScriptingEnumeration(
                            name: finished.name, code: finished.code, cases: finished.cases))
                }
                pendingEnumeration = nil
            case "class", "class-extension":
                if let finished = pendingClass {
                    // Hidden or nameless declarations are dropped whole: the manifest is
                    // what the query builder checks against, and garbage in it means a
                    // rung that looks real and answers nobody.
                    if !finished.hidden, !finished.name.isEmpty {
                        let managed = finished.manifest()
                        if finished.isExtension {
                            collectedExtensions.append(managed)
                        } else {
                            collectedClasses.append(managed)
                        }
                    }
                    pendingClass = nil
                    pendingProperty = nil
                }
            case "command", "event", "application-command":
                if let finished = pendingCommand {
                    if !finished.hidden, !finished.name.isEmpty {
                        collectedCommands.append(
                            (
                                name: finished.name, suite: finished.suite,
                                hidden: finished.hidden, directType: finished.resolvedDirectType,
                                eventClass: finished.eventClass, eventID: finished.eventID,
                                parameters: finished.parameters
                            ))
                    }
                    pendingCommand = nil
                }
            case "property":
                if let finished = pendingProperty, !finished.hidden,
                    let owner = pendingClass, !finished.name.isEmpty
                {
                    // The declared type: the attribute, or the first nested `<type>` —
                    // Mail's "message signature" declares its types that way.
                    let type = finished.nestedTypes.first { !$0.isEmpty } ?? ""
                    let property = ScriptingProperty(
                        name: finished.name,
                        // sdef types are already lowercase-ish; normalising makes the
                        // query builder's literal pick case-insensitive.
                        type: type.lowercased(),
                        isReadOnly: finished.access == "r",
                        isWriteOnly: finished.access == "w",
                        summary: finished.description,
                        code: finished.code)
                    owner.properties.append(property)
                }
                pendingProperty = nil
            case "direct-parameter":
                pendingCommand?.nestedDirectTypeCounter -= 1
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
            // Tolerant by construction: whatever was collected before the error stays —
            // a half-decoded manifest still names the classes the query builder checks.
        }
    }

    // MARK: Builder

    private final class ScriptingClassBuilder {
        let name: String
        let suite: String
        let code: String
        let plural: String
        let hidden: Bool
        /// A class-extension extends an existing class by name (`extends="application"`).
        let isExtension: Bool
        var properties: [ScriptingProperty] = []
        var elementTypes: [String] = []
        var respondsTo: [String] = []

        init(
            name: String, suite: String, code: String, plural: String, hidden: Bool,
            isExtension: Bool = false
        ) {
            self.name = name
            self.suite = suite
            self.code = code
            self.plural = plural
            self.hidden = hidden
            self.isExtension = isExtension
        }

        func manifest() -> ScriptingClass {
            ScriptingClass(
                name: name, suite: suite, plural: plural, properties: properties,
                elementTypes: elementTypes, respondsTo: respondsTo,
                code: code.isEmpty ? nil : code)
        }
    }

    /// Splits an sdef command `code` into the event class and event id a typed Apple
    /// Event needs. sdef prints the pair together for most apps (`spfyPaus` → class
    /// `spfy`, id `Paus`), a bare id for a few, and `????`/`****` for the Standard Suite.
    static func splitCommandCode(
        _ code: String, suiteCode: String
    ) -> (eventClass: String?, eventID: String?) {
        let chars = Array(code)
        if chars.count == 8 {
            return (String(chars[0..<4]), String(chars[4..<8]))
        }
        if chars.count == 4 {
            let usableSuite = suiteCode.count == 4 && !suiteCode.contains("?")
                && !suiteCode.contains("*")
            return (usableSuite ? suiteCode : nil, code)
        }
        return (nil, nil)
    }

    private final class ScriptingCommandBuilder {
        let name: String
        let suite: String
        let hidden: Bool
        let eventClass: String?
        let eventID: String?
        var directType: String?
        var nestedDirectTypeCounter = 0
        var nestedDirectTypeName: String?
        var parameters: [ScriptingParameter] = []

        init(name: String, suite: String, code: String, suiteCode: String, hidden: Bool) {
            self.name = name
            self.suite = suite
            self.hidden = hidden
            let split = AppSdefParser.splitCommandCode(code, suiteCode: suiteCode)
            self.eventClass = split.eventClass
            self.eventID = split.eventID
        }

        /// An attribute-declared direct type, else the nested `<type name="…">` one.
        var resolvedDirectType: String? {
            directType ?? (nestedDirectTypeCounter > 0 || nestedDirectTypeName != nil
                ? nestedDirectTypeName : nil)
        }
    }
}

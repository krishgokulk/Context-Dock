// AppDictionaryEvents.swift
// Context-Dock
//
// The dictionary rung's executor: validated plans in, typed Apple Events out. Nothing here
// renders AppleScript text and nothing spawns `osascript`; each operation is an
// `NSAppleEventDescriptor` aimed at the app by bundle id, sent with a bounded native
// timeout. Object references are built with `CreateObjSpecifier` from the four-character
// codes the app's own sdef declares, so an identifier that is not in the learned manifest
// cannot reach the app at all.
//
// Why typed events (owner review, P13 #208): the previous rung built a script string and
// ran it through `/usr/bin/osascript` with a watchdog. That is a scripting surface, not an
// Apple Event surface: it lets the rendered text drift, it pays a process per turn, and its
// only bound is a kill. A typed event has no text to drift, and `sendEvent(options:timeout:)`
// bounds the reply natively (`AXMessagingTimeout` is an accessibility API and does not apply
// to Apple Events). The app is never launched here: if it is not already running, the event
// is refused instead of starting it.
//
// Writes read the state back before claiming they worked (docs/architecture/
// CAPABILITY_LAYER.md: "Verification, not narration"). The registry marks a result verified
// only when the executor actually observed the new state.

import AppKit
import Carbon
import Foundation

/// A typed Apple Event failure with a sentence the model can act on.
enum AppDictionaryEventError: LocalizedError, Equatable {
    case notRunning(String)
    case missingCode(String)
    case refused(String)
    case appSaid(String)

    var errorDescription: String? {
        switch self {
        case .notRunning(let app):
            return "\(app) is not running. Open it first — DoraX will not launch it behind "
                + "your back for a dictionary read."
        case .missingCode(let term):
            return "\(term) has no four-character code in the app's dictionary, so a typed "
                + "Apple Event cannot address it."
        case .refused(let reason):
            return reason
        case .appSaid(let message):
            return message
        }
    }
}

/// What one typed operation returned.
struct AppDictionaryExecution: Sendable {
    let success: Bool
    let text: String
    /// The state the executor read back after a write or command, when it observed one.
    /// Nil means "ran, but nothing was independently confirmed" — never inferred.
    let readBack: String?
    let rows: [DictionaryQueryRow]
}

/// Builds and sends one validated plan against one learned manifest.
///
/// Every builder method is pure and internal so tests can inspect the descriptor an
/// operation would send, offline — the test host blocks `sendEvent` on purpose.
struct AppDictionaryEvents: Sendable {
    let dictionary: AppScriptingDictionary
    let bundleID: String
    let appName: String

    private static let timeout: TimeInterval = 10
    /// After a command, give the app a moment to settle before reading state back.
    private static let commandSettleDelay: TimeInterval = 0.25

    init(dictionary: AppScriptingDictionary) {
        self.dictionary = dictionary
        self.bundleID = dictionary.bundleID
        self.appName = dictionary.appName.isEmpty ? dictionary.bundleID : dictionary.appName
    }

    // MARK: Execute

    /// Run the plan. Never called on the main thread: `sendEvent` blocks until the app
    /// replies (or the timeout fires), so callers run this in a detached task.
    func execute(_ plan: DictionaryPlan) -> AppDictionaryExecution {
        do {
            switch plan {
            case .read(let target, let properties, let limit):
                return try read(target: target, properties: properties, limit: limit)
            case .count(let target):
                return try countResult(target)
            case .set(let target, let property, let value):
                return try set(target: target, property: property, value: value)
            case .make(let className, let assignments):
                return try make(className: className, assignments: assignments)
            case .delete(let target):
                return try delete(target)
            case .command(let command, let value):
                return try runCommand(command, value: value)
            }
        } catch {
            let text = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return AppDictionaryExecution(
                success: false, text: text, readBack: nil, rows: [])
        }
    }

    // MARK: Reads

    private func read(
        target: DictionaryTarget, properties: [ScriptingProperty], limit: Int
    ) throws -> AppDictionaryExecution {
        let targetSpecifier = try specifier(for: target)
        let total = target.isCollection ? try count(of: targetSpecifier) : 1
        let className = target.className.name
        guard total > 0 else {
            return AppDictionaryExecution(
                success: true, text: "No \(className)s matched.", readBack: nil, rows: [])
        }
        let take = min(total, max(1, limit))
        var columns: [[String]] = []
        var lastError: Error?
        for property in properties {
            do {
                let event = try readEvent(
                    specifier: propertySpecifier(property, of: targetSpecifier))
                let reply = try send(event)
                var values = columnValues(reply, expected: total).map(stringValue)
                while values.count < total { values.append("") }
                columns.append(values)
            } catch {
                // One unreadable property must not lose the rest of the row.
                lastError = error
                columns.append(Array(repeating: "", count: total))
            }
        }
        guard columns.contains(where: { column in
            column.prefix(take).contains { !$0.isEmpty }
        }) else {
            if let lastError { throw lastError }
            throw AppDictionaryEventError.refused(
                "\(appName) returned no readable values for \(className).")
        }
        let rows = (0..<take).map { index in
            DictionaryQueryRow(values: columns.map { $0[index] })
        }
        return AppDictionaryExecution(
            success: true,
            text: AppDictionaryQuery.answerLine(for: rows, className: className),
            readBack: nil,
            rows: rows)
    }

    private func countResult(_ target: DictionaryTarget) throws -> AppDictionaryExecution {
        let total = try count(of: try specifier(for: target))
        let className = target.className.name
        return AppDictionaryExecution(
            success: true,
            text: total == 1
                ? "1 \(className) matched."
                : "\(total) \(className)s matched.",
            readBack: nil,
            rows: [])
    }

    private func count(of specifier: NSAppleEventDescriptor) throws -> Int {
        let event = try countEvent(specifier)
        return Int(try send(event).int32Value)
    }

    /// The object references a `whose` (or every) collection resolves to. Used before a
    /// write so the card's set of objects is the set that actually changes.
    private func matchingItems(
        _ targetSpecifier: NSAppleEventDescriptor
    ) throws -> [NSAppleEventDescriptor] {
        let event = try readEvent(specifier: targetSpecifier)
        let reply = try send(event)
        if reply.descriptorType == typeAEList {
            let count = reply.numberOfItems
            guard count > 0 else { return [] }
            return (1...count).compactMap { reply.atIndex($0) }
        }
        if reply.descriptorType == typeNull { return [] }
        return [reply]
    }

    // MARK: Writes

    private func set(
        target: DictionaryTarget, property: ScriptingProperty, value: String
    ) throws -> AppDictionaryExecution {
        let targetSpecifier = try specifier(for: target)
        let items = try matchingItems(targetSpecifier)
        let className = target.className.name
        guard !items.isEmpty else {
            return AppDictionaryExecution(
                success: true, text: "No \(className)s matched, so nothing changed.",
                readBack: nil, rows: [])
        }
        guard items.count <= AppDictionaryQuery.maximumWrites else {
            throw AppDictionaryEventError.refused(
                "That filter matches \(items.count) \(className)s. Narrow it to "
                    + "\(AppDictionaryQuery.maximumWrites) or fewer so the approval covers "
                    + "exactly what changes.")
        }

        var changed: [String] = []
        var mismatched: [String] = []
        var failure: Error?
        for item in items {
            do {
                let propertySpecifier = try propertySpecifier(property, of: item)
                _ = try send(setEvent(
                    propertySpecifier, value: value, type: property.type))
                let observed = stringValue(
                    try send(readEvent(specifier: propertySpecifier)))
                changed.append(observed)
                if !matches(value, observed, type: property.type) {
                    mismatched.append(observed)
                }
            } catch {
                failure = error
                break
            }
        }
        if let failure, changed.count < items.count {
            throw AppDictionaryEventError.refused(
                "Changed \(property.name) on \(changed.count) of \(items.count) \(className)s, "
                    + "then stopped: \(failure.localizedDescription)")
        }
        if mismatched.isEmpty {
            let readBack = "\(property.name) is now \(changed.first ?? value)"
            let sample = Array(Set(changed)).prefix(3).joined(separator: ", ")
            return AppDictionaryExecution(
                success: true,
                text: "Changed \(property.name) on \(items.count) \(className)"
                    + (items.count == 1 ? "" : "s")
                    + " in \(appName) — read back: \(sample)",
                readBack: readBack,
                rows: [])
        }
        return AppDictionaryExecution(
            success: false,
            text: "Sent the change to \(items.count) \(className)"
                + (items.count == 1 ? "" : "s")
                + " in \(appName), but reading it back still shows "
                + "\(mismatched.first ?? "a different value") — the app did not take it.",
            readBack: nil,
            rows: [])
    }

    private func delete(_ target: DictionaryTarget) throws -> AppDictionaryExecution {
        let targetSpecifier = try specifier(for: target)
        let className = target.className.name
        let before = try count(of: targetSpecifier)
        let items = try matchingItems(targetSpecifier)
        guard !items.isEmpty else {
            return AppDictionaryExecution(
                success: true, text: "No \(className)s matched, so nothing was deleted.",
                readBack: nil, rows: [])
        }
        guard items.count <= AppDictionaryQuery.maximumWrites else {
            throw AppDictionaryEventError.refused(
                "That filter matches \(items.count) \(className)s. Narrow it to "
                    + "\(AppDictionaryQuery.maximumWrites) or fewer so the approval covers "
                    + "exactly what is deleted.")
        }

        var deleted = 0
        var failure: Error?
        for item in items {
            do {
                _ = try send(deleteEvent(item))
                deleted += 1
            } catch {
                failure = error
                break
            }
        }
        if deleted == 0, let failure { throw failure }
        let after = (try? count(of: targetSpecifier)) ?? max(0, before - deleted)
        let observed = after < before
        return AppDictionaryExecution(
            success: observed,
            text: "Deleted \(deleted) of \(items.count) \(className)"
                + (items.count == 1 ? "" : "s")
                + (observed
                    ? " — \(after) left (was \(before))."
                    : " — could not confirm the count afterwards."),
            readBack: observed ? "\(after) \(className)s left (was \(before))" : nil,
            rows: [])
    }

    private func make(
        className: ScriptingClass, assignments: [DictionaryAssignment]
    ) throws -> AppDictionaryExecution {
        let collection = try specifier(
            for: .collection(className: className, filter: nil))
        let before = try? count(of: collection)
        let event = try makeEvent(className: className, assignments: assignments)
        _ = try send(event)
        let after = try? count(of: collection)
        let readBack: String?
        if let before, let after, after > before {
            readBack = "\(after) \(className.name)s now (was \(before))"
        } else {
            readBack = nil
        }
        let description = assignments.isEmpty
            ? "Created a new \(className.name) in \(appName)"
            : "Created a new \(className.name) in \(appName) ("
                + assignments.map(\.property.name).joined(separator: ", ") + ")"
        return AppDictionaryExecution(
            success: readBack != nil,
            text: readBack.map { "\(description) — \($0)." }
                ?? "\(description) — the app did not confirm the new count.",
            readBack: readBack,
            rows: [])
    }

    // MARK: Commands

    private func runCommand(
        _ command: ScriptingCommand, value: String
    ) throws -> AppDictionaryExecution {
        let before = snapshotAppState()
        let event = try commandEvent(command, value: value)
        _ = try send(event)
        Thread.sleep(forTimeInterval: Self.commandSettleDelay)
        let after = snapshotAppState()

        let changes = before.keys.sorted().compactMap { key -> String? in
            guard let old = before[key], let new = after[key], old != new else { return nil }
            return "\(key) is now \(new)"
        }
        let readBack = changes.isEmpty ? nil : changes.joined(separator: "; ")
        return AppDictionaryExecution(
            success: true,
            text: "Ran \"\(command.name)\" in \(appName)"
                + (readBack.map { " — \($0)" } ?? " — no readable state changed."),
            readBack: readBack,
            rows: [])
    }

    /// The app object's own scalar, readable properties, by name. Used around a command so
    /// a change caused by it can actually be observed. Real-valued properties (a player
    /// position, a progress counter) are excluded: they move on their own and would make a
    /// command look verified when nothing happened.
    private func snapshotAppState() -> [String: String] {
        var snapshot: [String: String] = [:]
        let appClasses = dictionary.classes.filter {
            $0.name.lowercased() == "application"
        }
        for appClass in appClasses {
            for property in appClass.properties where !property.isWriteOnly {
                guard property.code != nil, isScalar(property.type) else { continue }
                do {
                    let specifier = try propertySpecifier(property, of: .null())
                    let value = stringValue(try send(readEvent(specifier: specifier)))
                    if !value.isEmpty { snapshot[property.name] = value }
                } catch {
                    continue
                }
            }
        }
        return snapshot
    }

    private func isScalar(_ type: String) -> Bool {
        let normalized = type.lowercased()
        if ["text", "integer", "boolean", "bool"].contains(normalized) { return true }
        if ["real", "number"].contains(normalized) { return false }
        return dictionary.enumerations.contains {
            $0.name.lowercased() == normalized
        }
    }

    // MARK: Descriptor construction

    /// The object reference a target names. `nil` container means the application object.
    func specifier(for target: DictionaryTarget) throws -> NSAppleEventDescriptor {
        switch target {
        case .application:
            return NSAppleEventDescriptor.null()
        case .singleItem(_, let root):
            return try propertySpecifier(root, of: .null())
        case .collection(let className, let filter):
            let classCode = try ostype(className.code, term: "class \"\(className.name)\"")
            if let filter {
                let comparison = try comparisonDescriptor(filter)
                return try objectSpecifier(
                    desiredClass: classCode,
                    form: DescType(formTest),
                    keyData: comparison,
                    container: .null())
            }
            return try objectSpecifier(
                desiredClass: classCode,
                form: DescType(formAbsolutePosition),
                keyData: try absoluteOrdinal("all "),
                container: .null())
        }
    }

    /// `property of container` — the reference every read and set is aimed at.
    func propertySpecifier(
        _ property: ScriptingProperty, of container: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        let code = try ostype(
            property.code, term: "property \"\(property.name)\"")
        return try objectSpecifier(
            desiredClass: DescType(typeProperty),
            form: DescType(formPropertyID),
            keyData: NSAppleEventDescriptor(typeCode: code),
            container: container)
    }

    func readEvent(specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let event = try makeEvent(
            eventClass: OSType(kAECoreSuite), eventID: OSType(kAEGetData))
        event.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    func countEvent(_ specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let event = try makeEvent(
            eventClass: OSType(kAECoreSuite), eventID: OSType(kAECountElements))
        event.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    func setEvent(
        _ propertySpecifier: NSAppleEventDescriptor, value: String, type: String
    ) throws -> NSAppleEventDescriptor {
        let event = try makeEvent(eventClass: OSType(kAECoreSuite), eventID: OSType(kAESetData))
        event.setParam(propertySpecifier, forKeyword: AEKeyword(keyDirectObject))
        event.setParam(try typedValue(value, type: type), forKeyword: AEKeyword(keyAEData))
        return event
    }

    func deleteEvent(_ item: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let event = try makeEvent(eventClass: OSType(kAECoreSuite), eventID: OSType(kAEDelete))
        event.setParam(item, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    func makeEvent(
        className: ScriptingClass, assignments: [DictionaryAssignment]
    ) throws -> NSAppleEventDescriptor {
        let classCode = try ostype(className.code, term: "class \"\(className.name)\"")
        let event = try makeEvent(
            eventClass: OSType(kAECoreSuite), eventID: OSType(kAECreateElement))
        // A `make new <class>` inside `tell application` puts the new element in the app.
        event.setParam(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyDirectObject))
        event.setParam(
            NSAppleEventDescriptor(typeCode: classCode), forKeyword: AEKeyword(keyAEObjectClass))
        guard !assignments.isEmpty else { return event }
        let properties = NSAppleEventDescriptor.record()
        for assignment in assignments {
            let code = try ostype(
                assignment.property.code, term: "property \"\(assignment.property.name)\"")
            properties.setDescriptor(
                try typedValue(assignment.value, type: assignment.property.type),
                forKeyword: code)
        }
        event.setParam(properties, forKeyword: AEKeyword(keyAEPropData))
        return event
    }

    func commandEvent(
        _ command: ScriptingCommand, value: String
    ) throws -> NSAppleEventDescriptor {
        let eventClass = try ostype(
            command.eventClass, term: "command \"\(command.name)\"")
        let eventID = try ostype(command.code, term: "command \"\(command.name)\"")
        let event = try makeEvent(eventClass: eventClass, eventID: eventID)
        if !value.isEmpty {
            event.setParam(
                NSAppleEventDescriptor(string: value), forKeyword: AEKeyword(keyDirectObject))
        }
        return event
    }

    /// `want class, form form, keyData, from container` — the four-record object specifier
    /// every Apple Event reference is made of. Built with the Carbon helper rather than by
    /// assembling the record by hand.
    private func objectSpecifier(
        desiredClass: OSType, form: DescType,
        keyData: NSAppleEventDescriptor, container: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        guard var containerDesc = container.aeDesc?.pointee,
            var keyDesc = keyData.aeDesc?.pointee
        else {
            throw AppDictionaryEventError.refused(
                "Could not build a typed reference to \(appName).")
        }
        var result = AEDesc()
        let status = CreateObjSpecifier(
            desiredClass, &containerDesc, form, &keyDesc, false, &result)
        guard status == noErr else {
            throw AppDictionaryEventError.refused(
                "Could not build a typed reference to \(appName) (\(status)).")
        }
        return NSAppleEventDescriptor(aeDescNoCopy: &result)
    }

    private func absoluteOrdinal(_ code: String) throws -> NSAppleEventDescriptor {
        let ordinal = fourCharCode(code) ?? OSType(0x616C6C20)  // 'all '
        // An AEDesc stores an OSType in native byte order, like `NSAppleEventDescriptor`'s
        // own `typeCodeValue` does; writing big-endian bytes here made "every track" a
        // different ordinal on Apple silicon.
        guard let descriptor = NSAppleEventDescriptor(
            descriptorType: typeAbsoluteOrdinal,
            data: withUnsafeBytes(of: ordinal) { Data($0) })
        else {
            throw AppDictionaryEventError.refused(
                "Could not build an ordinal reference for \(appName).")
        }
        return descriptor
    }

    private func comparisonDescriptor(
        _ filter: DictionaryFilter
    ) throws -> NSAppleEventDescriptor {
        let property = try propertySpecifier(filter.property, of: .null())
        let value = try typedValue(filter.value, type: filter.property.type)
        if filter.comparison == .isNot {
            return try logicalNot(
                comparisonDescriptor(left: property, operatorCode: OSType(kAEEquals), right: value))
        }
        return try comparisonDescriptor(
            left: property, operatorCode: operatorCode(filter.comparison), right: value)
    }

    private func operatorCode(_ comparison: DictionaryFilter.Comparison) -> OSType {
        switch comparison {
        case .isEqual, .isNot: return OSType(kAEEquals)
        case .contains: return OSType(kAEContains)
        case .beginsWith: return OSType(kAEBeginsWith)
        case .endsWith: return OSType(kAEEndsWith)
        case .greaterThan: return OSType(kAEGreaterThan)
        case .lessThan: return OSType(kAELessThan)
        }
    }

    /// `operand1 op operand2`, built by `CreateCompDescriptor` so the descriptor is a
    /// real `cmpd` whose operands are descriptors — not script text with a literal in it.
    private func comparisonDescriptor(
        left: NSAppleEventDescriptor, operatorCode: OSType, right: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        guard var leftDesc = left.aeDesc?.pointee,
            var rightDesc = right.aeDesc?.pointee
        else {
            throw AppDictionaryEventError.refused(
                "Could not build a filter for \(appName).")
        }
        var result = AEDesc()
        let status = CreateCompDescriptor(
            operatorCode, &leftDesc, &rightDesc, false, &result)
        guard status == noErr else {
            throw AppDictionaryEventError.refused(
                "Could not build a filter for \(appName) (\(status)).")
        }
        return NSAppleEventDescriptor(aeDescNoCopy: &result)
    }

    /// `not term` — a `logi` descriptor with `kAENOT` and one term. "is not" is defined by
    /// Apple as NOT (term is equal), not as a comparison operator of its own.
    private func logicalNot(
        _ term: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        guard var termDesc = term.aeDesc?.pointee else {
            throw AppDictionaryEventError.refused(
                "Could not build a filter for \(appName).")
        }
        var terms = AEDescList()
        var status = AECreateList(nil, 0, false, &terms)
        guard status == noErr else {
            throw AppDictionaryEventError.refused(
                "Could not build a filter for \(appName) (\(status)).")
        }
        status = AEPutDesc(&terms, 0, &termDesc)
        guard status == noErr else {
            AEDisposeDesc(&terms)
            throw AppDictionaryEventError.refused(
                "Could not build a filter for \(appName) (\(status)).")
        }
        var result = AEDesc()
        status = CreateLogicalDescriptor(
            &terms, DescType(kAENOT), true, &result)
        guard status == noErr else {
            throw AppDictionaryEventError.refused(
                "Could not build a filter for \(appName) (\(status)).")
        }
        return NSAppleEventDescriptor(aeDescNoCopy: &result)
    }

    private func typedValue(
        _ raw: String, type: String
    ) throws -> NSAppleEventDescriptor {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type.lowercased() {
        case "integer":
            if let value = Int32(trimmed) {
                return NSAppleEventDescriptor(int32: value)
            }
        case "real", "number":
            if let value = Double(trimmed) {
                return NSAppleEventDescriptor(double: value)
            }
        case "boolean", "bool":
            let lowered = trimmed.lowercased()
            if ["true", "false"].contains(lowered) {
                return NSAppleEventDescriptor(boolean: lowered == "true")
            }
            if lowered == "1" || lowered == "0" {
                return NSAppleEventDescriptor(boolean: lowered == "1")
            }
        default:
            break
        }
        if let enumeration = dictionary.enumerations.first(where: {
            $0.name.lowercased() == type.lowercased()
        }), let match = enumeration.cases.first(where: {
            $0.name.lowercased() == trimmed.lowercased()
        }), let code = fourCharCode(match.code) {
            return NSAppleEventDescriptor(enumCode: code)
        }
        return NSAppleEventDescriptor(string: raw)
    }

    private func makeEvent(
        eventClass: OSType, eventID: OSType
    ) throws -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: eventClass,
            eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
    }

    // MARK: Sending

    private func send(
        _ event: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).contains { !$0.isTerminated }
        guard running else {
            throw AppDictionaryEventError.notRunning(appName)
        }
        do {
            return try event.sendEvent(
                options: [.waitForReply, .neverInteract], timeout: Self.timeout)
        } catch let error as NSError {
            throw AppDictionaryEventError.appSaid(describe(error))
        }
    }

    private func describe(_ error: NSError) -> String {
        switch error.code {
        case -1728:
            return "\(appName) could not find that object (-1728)."
        case -1708:
            return "\(appName) does not handle that event (-1708)."
        case -1743:
            return "macOS has not allowed DoraX to control \(appName). Allow it in System "
                + "Settings → Privacy & Security → Automation."
        case -600:
            return "\(appName) is not running."
        case -1712:
            return "\(appName) did not answer within \(Int(Self.timeout)) s."
        default:
            let brief = (error.userInfo["NSAppleScriptErrorBriefMessage"] as? String)
                ?? error.userInfo[NSLocalizedDescriptionKey] as? String
            return brief ?? "\(appName) refused the Apple Event (\(error.code))."
        }
    }

    // MARK: Reply values

    /// One property's reply as one value per row. A list reply is one value per matching
    /// object; a single-object target keeps even a list-valued property as one value.
    private func columnValues(
        _ reply: NSAppleEventDescriptor, expected: Int
    ) -> [NSAppleEventDescriptor] {
        guard expected > 1, reply.descriptorType == typeAEList else { return [reply] }
        let count = reply.numberOfItems
        guard count > 0 else { return [] }
        return (1...count).compactMap { reply.atIndex($0) }
    }

    private func stringValue(_ descriptor: NSAppleEventDescriptor) -> String {
        switch descriptor.descriptorType {
        case typeUnicodeText, typeText:
            return descriptor.stringValue ?? ""
        case typeSInt16, typeSInt32:
            return String(descriptor.int32Value)
        case typeSInt64:
            let data = descriptor.data
            guard data.count >= 8 else { return "" }
            // `Data` is not guaranteed 8-byte aligned; an aligned `load` would trap.
            return String(
                data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) })
        case typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint:
            return String(descriptor.doubleValue)
        case typeBoolean:
            return descriptor.booleanValue ? "true" : "false"
        case typeEnumerated:
            let code = fourCharText(descriptor.enumCodeValue)
            return enumerationName(forCode: code) ?? code
        case typeAEList:
            let count = descriptor.numberOfItems
            guard count > 0 else { return "" }
            return (1...count)
                .compactMap { descriptor.atIndex($0) }
                .map(stringValue)
                .joined(separator: ", ")
        case typeFileURL:
            return descriptor.fileURLValue?.path ?? descriptor.stringValue ?? ""
        case typeNull:
            return ""
        default:
            return descriptor.stringValue ?? ""
        }
    }

    private func enumerationName(forCode code: String) -> String? {
        for enumeration in dictionary.enumerations {
            if let name = enumeration.name(forCode: code) { return name }
        }
        return nil
    }

    /// Did the app take the value? Compared the way a person reads it: case-insensitive
    /// text, numeric equality, and boolean spellings.
    private func matches(_ requested: String, _ observed: String, type: String) -> Bool {
        let left = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = observed.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.caseInsensitiveCompare(right) == .orderedSame { return true }
        if let lhs = Double(left), let rhs = Double(right), lhs == rhs { return true }
        let booleans = ["true": "1", "false": "0"]
        if let lhs = booleans[left.lowercased()], lhs == right { return true }
        if let rhs = booleans[right.lowercased()], rhs == left { return true }
        return false
    }
}

// MARK: - Four-character codes

/// A four-character sdef/OSType code (`pnam`) as the integer Apple Events carry.
func fourCharCode(_ text: String) -> OSType? {
    let bytes = Array(text.utf8)
    guard bytes.count == 4 else { return nil }
    return bytes.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
}

/// The printable form of an OSType. Non-printing bytes become spaces, the convention the
/// Apple Event tools themselves use.
func fourCharText(_ code: OSType) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
    ]
    return String(bytes.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : " " })
}

private extension AppDictionaryEvents {
    /// A missing code is a validation failure upstream; this keeps the event builders
    /// honest if a caller ever reaches them with one.
    func ostype(_ code: String?, term: String) throws -> OSType {
        guard let code, let value = fourCharCode(code) else {
            throw AppDictionaryEventError.missingCode(term)
        }
        return value
    }
}

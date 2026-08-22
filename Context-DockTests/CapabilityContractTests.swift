// CapabilityContractTests.swift
// Context-DockTests
//
// What every capability promises before it is ever called.
//
// The discovery suite checks which capability a question reaches. It says nothing about
// whether that capability is safe to reach, and the things added this week are the first
// that type into documents, click menus and delete files. Those need a different kind of
// check: not "does it work" — that needs a person watching a screen — but "is it declared
// correctly", which is exactly the part a person watching a screen cannot see.
//
// Every failure here is a real hazard rather than a style complaint. A destructive
// capability marked .low executes with no approval sheet. A capability reachable from
// Selection Scope while touching unrelated state breaks the promise that scope makes. An
// input the executor requires but the schema does not declare fails at run time, in front
// of the user, after they approved it.

import XCTest

@testable import Context_Dock

@MainActor
final class CapabilityContractTests: XCTestCase {

    private var registry: CapabilityRegistry { CapabilityRegistry.shared }

    private func capability(_ id: String) throws -> AICapability {
        try XCTUnwrap(registry.capability(id: id), "\(id) is not registered")
    }

    // MARK: - The week's new capabilities exist at all

    /// Registration is not a formality: an unregistered id parses, resolves, and then dies
    /// with "no such capability". app.menu.click spent months in the invocation parser
    /// without ever being registered, so "minimize safari" resolved correctly and ran
    /// nothing.
    func testNewCapabilitiesAreRegistered() throws {
        for id in [
            "browser.history", "browser.bookmarks", "browser.currentPage", "browser.tabs",
            "files.recentDocuments", "files.search",
            "quicknotes.search", "apps.mostUsed",
            "clipboard.history", "extensions.list",
            "cli.list", "cli.run",
            "memory.search", "memory.save",
            "capture.text", "capture.area",
            "app.menu.click", "app.insertText",
            "project.build",
        ] {
            XCTAssertNotNil(registry.capability(id: id), "\(id) is not registered")
        }
    }

    // MARK: - Consequence is declared honestly

    /// Anything that writes, deletes, types or runs code must require approval. `.low`
    /// skips the approval sheet entirely, so a mislabelled capability here is one that acts
    /// on the user's machine without asking.
    func testActingCapabilitiesRequireApproval() throws {
        for id in [
            "app.insertText",  // types into a document
            "app.menu.click",  // can be Quit, or Delete
            "project.build",  // runs a script from the repository
            "cli.run",  // runs a linked binary
            "memory.save",  // changes what the user is told later
            "finder.trash",  // deletes
        ] {
            let capability = try self.capability(id)
            XCTAssertTrue(
                capability.riskLevel.requiresApproval,
                "\(id) is \(capability.riskLevel.rawValue) — it would run with no approval")
        }
    }

    /// Reads stay cheap. A read marked high would put an approval sheet in front of every
    /// ordinary question, which trains people to approve without reading — the failure that
    /// makes every other approval worthless.
    func testReadsDoNotDemandApproval() throws {
        for id in [
            "browser.history", "browser.bookmarks", "browser.currentPage", "browser.tabs",
            "files.recentDocuments", "files.search", "quicknotes.search",
            "apps.mostUsed", "clipboard.history", "extensions.list",
            "cli.list", "memory.search",
        ] {
            let capability = try self.capability(id)
            XCTAssertFalse(
                capability.riskLevel.requiresApproval,
                "\(id) is a read but demands approval")
        }
    }

    // MARK: - Selection Scope keeps its promise

    /// Selection Scope acts on what the user selected. A capability that reaches beyond it
    /// must not be reachable from there, whatever its id looks like.
    func testNothingUnsafeIsReachableFromSelectionScope() throws {
        for id in [
            "app.insertText", "app.menu.click", "project.build", "cli.run",
            "finder.trash", "browser.history", "memory.save", "capture.area",
        ] {
            let capability = try self.capability(id)
            XCTAssertFalse(
                capability.selectionSafety.isSelectionSafe,
                "\(id) claims to be selection-safe while touching state outside the selection")
        }
    }

    /// The default must stay strict. A capability added later without thinking about
    /// Selection Scope has to be unreachable from it, or the scope widens by omission —
    /// which is the failure an allowlist has by construction.
    func testSelectionSafetyDefaultsToUnsafe() {
        XCTAssertFalse(SelectionSafety.unsafe.isSelectionSafe)
        XCTAssertTrue(SelectionSafety.readsSelection.isSelectionSafe)
        XCTAssertTrue(SelectionSafety.rewritesSelection.isSelectionSafe)
        // Reading only the selection but writing elsewhere is not selection-safe: "create a
        // reminder from this" starts in the selection and lands in another app.
        let leaks = SelectionSafety(
            inputAuthority: .selectionOnly, sideEffect: .unrelatedState,
            targetScope: .currentSelection)
        XCTAssertFalse(leaks.isSelectionSafe)
    }

    // MARK: - Schemas match what the executors actually need

    /// An input the executor requires must be declared required, or the engine's own
    /// missing-input check never fires and the failure surfaces from inside the executor
    /// after the user has already approved it.
    func testRequiredInputsAreDeclared() throws {
        let expected: [String: Set<String>] = [
            "app.insertText": ["text"],
            "app.menu.click": ["path"],
            "cli.run": ["command"],
            "memory.save": ["text"],
            "files.search": ["query"],
        ]
        for (id, required) in expected {
            let fields = try capability(id).inputSchema.fields
            let declared = Set(fields.filter(\.required).map(\.name))
            XCTAssertEqual(
                declared, required,
                "\(id) declares required inputs \(declared.sorted()), expected \(required.sorted())")
        }
    }

    /// Optional inputs still have to be described — the description is the only thing the
    /// model sees when deciding what to pass, and an undescribed field is one it will guess
    /// at or ignore.
    func testEveryInputFieldIsDescribed() throws {
        for capability in registry.all {
            for field in capability.inputSchema.fields {
                XCTAssertFalse(
                    field.description.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(capability.id).\(field.name) has no description")
            }
        }
    }

    // MARK: - Ids and titles

    /// Discovery matches on id and title, so an empty title makes a capability findable
    /// only by exact id — which the model has no way to guess.
    func testEveryCapabilityHasATitle() {
        for capability in registry.all {
            XCTAssertFalse(
                capability.title.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(capability.id) has no title")
        }
    }

    /// Ids are dotted, which the invocation parser relies on: the id-as-key envelope is
    /// recognised by exactly that shape.
    func testCapabilityIDsAreDotted() {
        for capability in registry.all {
            XCTAssertTrue(
                capability.id.contains("."),
                "\(capability.id) is not dotted — the id-as-key envelope will not match it")
        }
    }
}

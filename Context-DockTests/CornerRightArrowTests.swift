// Context-DockTests/CornerRightArrowTests.swift
//
// → on a focused row steps into it and never runs it. It used to run any row: → on
// "Sleep" put the Mac to sleep (parity inventory D4).

import Foundation
import Testing

@testable import Context_Dock

@MainActor
private func document(
    _ title: String, _ action: GlobalSearchService.ActionSpec
) -> GlobalSearchService.SearchDocument {
    GlobalSearchService.SearchDocument(
        id: title, title: title, subtitle: "", bundleId: "", filePath: nil,
        normalizedTitle: title.lowercased(), titleWords: [title.lowercased()],
        acronym: String(title.prefix(1)), aliases: [], aliasWords: [], sourceKind: .cli,
        rankingBoost: 0, icon: nil, usageTrackingKey: title, action: action)
}

@Suite("Corner right arrow")
@MainActor
struct CornerRightArrowTests {

    private func globalModel(_ rows: [AppChatRow]) -> AppChatPromptModel {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        model.summonGlobalContext()
        model.rows = rows
        model.moveMenuFocus(by: 1)
        return model
    }

    @Test("→ steps into scopes and nothing else")
    func onlyScopesAreSteppedIntoByRunning() {
        typealias A = GlobalSearchService.ActionSpec
        let into: [A] = [
            .systemCommandScope(commandKey: UUID().uuidString), .userExtension(id: UUID()),
            .cliScope(command: "git", displayName: "git"),
        ]
        let not: [A] = [
            .launchPath("/System/Applications/Calculator.app"),
            .cachedMenu(
                bundleId: "b", appName: "A", path: ["File", "Close"], shortcutChar: nil,
                shortcutModifiers: 0),
            .adapterAction(bundleId: "b", appName: "A", actionId: "x"),
            .browserURL(
                url: URL(string: "https://a.b")!, browserBundleId: "b", browserName: "B",
                kind: "tab", domain: "a.b"),
            .plugin(id: "p"),
        ]
        for action in into { #expect(AppChatPromptModel.rightArrowStepsInto(action)) }
        for action in not { #expect(!AppChatPromptModel.rightArrowStepsInto(action)) }
    }

    @Test("→ on a one-shot row does nothing, and leaves the row where it was")
    func aOneShotRowIsNotRun() {
        let model = globalModel([.global(document("Sleep", .launchPath("/nonexistent/Sleep")))])
        #expect(model.stepIntoFocusedRow() == false)
        #expect(model.focusedRow != nil)
        #expect(model.isGlobalScope)
    }

    @Test("→ on an app row scopes into the app instead of launching it")
    func anAppRowIsScopedInto() {
        let model = globalModel([.global(document(
            "Calculator",
            .launchBundleId("com.apple.calculator", path: "/System/Applications/Calculator.app")))])
        #expect(model.stepIntoFocusedRow())
        #expect(model.appBundleID == "com.apple.calculator")
        #expect(model.returnsToGlobalScope)
    }

    @Test("↑/↓ try the layer first only on an empty field with nothing highlighted")
    func theLayerComesFirstOnlyWhenNothingIsChosen() {
        #expect(AppChatPromptModel.layerKeyComesFirst(query: "", hasFocusedRow: false))
        #expect(!AppChatPromptModel.layerKeyComesFirst(query: "", hasFocusedRow: true))
        #expect(!AppChatPromptModel.layerKeyComesFirst(query: "saf", hasFocusedRow: false))
    }
}

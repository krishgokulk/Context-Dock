// Context-DockTests/CornerLivePanelTests.swift
//
// The Context Dock's live panel (#191, part 2): while an app's chat answers, the card's
// right half shows the steps, a command's output and the connectors in play — and closes
// when the turn ends.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Context Dock live panel")
@MainActor
struct CornerLivePanelTests {
    typealias L = CornerLivePanelLayout

    @Test("Only an app's conversation, while open, once there is a turn")
    func showsBesideAnAppsConversation() {
        #expect(L.shows(isAppScope: true, phase: .chat, isOpen: true, hasConversation: true))
        // Stays after the turn ends, as Claude's panel does; the toggle hides it.
        #expect(!L.shows(isAppScope: true, phase: .chat, isOpen: false, hasConversation: true))
        // Nothing asked yet: nothing to show.
        #expect(!L.shows(isAppScope: true, phase: .chat, isOpen: true, hasConversation: false))
        // Global's results have their own preview.
        #expect(!L.shows(isAppScope: false, phase: .chat, isOpen: true, hasConversation: true))
        // Not over the field, the list or the dock.
        for phase in [AppChatPromptPhase.prompt, .suggesting, .dock, .mini, .hidden] {
            #expect(!L.shows(isAppScope: true, phase: phase, isOpen: true, hasConversation: true))
        }
    }

    @Test("The conversation keeps the larger part of the card")
    func thePanelIsTheSmallerColumn() {
        let card = DockShellWidth.base
        let panel = L.panelWidth(card: card)
        #expect(panel < card / 2)
        #expect(panel >= 240, "room for a step, a file and its kind")
    }

    @Test("The panel lists the running turn's steps, else the last finished turn's")
    func stepsFollowTheTurn() {
        let live = [ActivityStep(kind: .command, title: "Running ls", detail: "ls")]
        let done = [ActivityStep(kind: .read, title: "Read status", status: .ok)]
        #expect(L.steps(isAnswering: true, live: live, finished: done).map(\.id) == live.map(\.id))
        #expect(L.steps(isAnswering: false, live: [], finished: done).map(\.id) == done.map(\.id))
    }

    @Test("Uploads: every attachment in the conversation, once each, oldest first")
    func uploadsAreListedOnce() {
        let csv = URL(fileURLWithPath: "/tmp/passports.csv")
        let png = URL(fileURLWithPath: "/tmp/shot.png")
        #expect(L.uploads([]).isEmpty)
        #expect(L.uploads([[csv], [], [png, csv]]) == [csv, png])
    }

    @Test("A command's output is quoted from its end")
    func outputIsTheTail() {
        #expect(L.outputTail("") == "")
        #expect(L.outputTail("one\ntwo\n\n") == "one\ntwo")
        let long = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let tail = L.outputTail(long, lines: 5)
        #expect(tail.hasPrefix("…\n"))
        #expect(tail.hasSuffix("line 40"))
        #expect(tail.components(separatedBy: "\n").count == 6)
        #expect(!tail.contains("line 35"))
    }

    @Test("The terminal follows the command running now, else the last that spoke")
    func theTerminalStep() {
        let read = ActivityStep(kind: .read, title: "Read status", status: .ok, output: "x")
        let first = ActivityStep(kind: .command, title: "Ran ls", detail: "ls", status: .ok, output: "a\nb")
        let quiet = ActivityStep(kind: .providerShell, title: "Ran true", detail: "true", status: .ok)
        #expect(L.terminalStep(in: [read]) == nil)
        #expect(L.terminalStep(in: [read, first, quiet])?.id == first.id)
        let running = ActivityStep(kind: .command, title: "Running make", detail: "make")
        #expect(L.terminalStep(in: [first, running, quiet])?.id == running.id)
    }

    @Test("Connectors: the app's linked servers, then any other the turn called, once each")
    func connectorsAreNamedOnce() {
        let call = ActivityStep(kind: .mcp, title: "Ran search_issues via github", status: .running)
        let other = ActivityStep(kind: .mcp, title: "Ran list_issues via linear", status: .ok)
        let bare = ActivityStep(kind: .mcp, title: "Ran fetch", status: .ok)
        let shell = ActivityStep(kind: .command, title: "Ran ls")
        #expect(L.connectors(linked: [], steps: [shell]).isEmpty)
        #expect(
            L.connectors(linked: ["github"], steps: [call, other, shell, bare])
                == ["github", "linear", "fetch"])
        #expect(L.server(of: call) == "github")
    }

    @Test("A fresh model shows no panel")
    func aFreshModelShowsNone() {
        let model = AppChatPromptModel(conversation: AppChatConversation())
        #expect(!model.showsLivePanel)
    }
}

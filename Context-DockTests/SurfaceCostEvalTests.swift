import Foundation
import Testing

@testable import Context_Dock

/// Per-app cases from `docs/superpowers/specs/2026-09-23-surface-cost-and-computer-use.md` §8.
///
/// The format is the point: what was asked, what the index holds, what each path costs, and
/// which decision that must produce. Offline and deterministic — no model, no app, no menus.
///
/// The question these are all really asking is §9's fourth: **did a screen-taking path run
/// while a headless one existed?** That is the one bug this whole axis exists to prevent, and
/// it is checkable without the request needing to succeed.
@Suite("Surface cost per app")
struct SurfaceCostEvalTests {

    private func hit(
        _ id: String, _ score: Double, _ surface: CapabilityRecord.Surface,
        app: String = "App", write: Bool = true
    ) -> CapabilityIndex.Hit {
        .init(
            record: CapabilityRecord(
                id: id, app: app, kind: .capability, title: id, isWrite: write,
                surface: surface),
            score: score, matched: ["x"], coverage: 1.0)
    }

    /// The report. Claude Desktop has a linked CLI and a cached `File ▸ New Chat`; both could
    /// start something and they do not produce the same thing, so the user chooses.
    @Test func claudeNewChatOffersTheCLIAndTheMenu() throws {
        let decision = CapabilityDecision.make(from: [
            hit("claude.cli.newChat", 11.4, .headless, app: "Claude"),
            hit("claude.menu.newChat", 10.9, .opensApp, app: "Claude"),
        ])

        guard case .ask(let offered) = decision else {
            Issue.record("expected a choice, got \(decision.summary)"); return
        }
        #expect(offered.first?.record.surface == .headless)
        #expect(decision.summary.contains("no window opens"))
    }

    /// App Store: nothing headless can update apps, and the Update All button is on screen.
    /// Driving the UI is the answer here, not a failure to find one.
    @Test func appStoreUpdateAllIsTheScreenBecauseNothingElseCanDoIt() {
        let screen = hit("appstore.updateAll", 12.4, .takesScreen, app: "App Store")

        #expect(CapabilityDecision.make(from: [screen]) == .act(screen))
    }

    /// Finder: three able paths, one of them far ahead and headless. Must not become a
    /// question — this is the case that keeps the rule from turning into a prompt on every
    /// request.
    @Test func finderEmptyTrashJustRuns() {
        let action = hit("finder.emptyTrash", 14.2, .headless, app: "Finder")

        #expect(
            CapabilityDecision.make(from: [
                action,
                hit("finder.menu.emptyTrash", 6.1, .opensApp, app: "Finder"),
                hit("finder.computerUse", 4.0, .takesScreen, app: "Finder"),
            ]) == .act(action))
    }

    /// VS Code: two headless reads of the same thing. Same cost, so the ranking decides and
    /// nobody is asked.
    @Test func vsCodeExtensionListIsRankedNotAsked() {
        let capability = hit("vscode.extensions.list", 12.0, .headless, app: "Code", write: false)

        #expect(
            CapabilityDecision.make(from: [
                capability,
                hit("vscode.cli.listExtensions", 10.4, .headless, app: "Code", write: false),
            ]) == .act(capability))
    }

    /// Calendar: a question with a headless read. Never an offer, never opens anything.
    @Test func calendarTomorrowReadsWithoutOpeningAnything() {
        let reader = hit("calendar.list", 12.0, .headless, app: "Calendar", write: false)

        #expect(CapabilityDecision.make(from: [reader]) == .act(reader))
    }

    /// ChatGPT: a stale menu map and the live UI are both plausible and differ in cost, so
    /// the user chooses rather than DoraX betting on the cache.
    @Test func chatGPTNewChatOffersTheMenuAndTheScreen() throws {
        let decision = CapabilityDecision.make(from: [
            hit("chatgpt.menu.newChat", 11.0, .opensApp, app: "ChatGPT"),
            hit("chatgpt.computerUse", 10.2, .takesScreen, app: "ChatGPT"),
        ])

        guard case .ask(let offered) = decision else {
            Issue.record("expected a choice, got \(decision.summary)"); return
        }
        #expect(offered.map(\.record.surface) == [.opensApp, .takesScreen])
    }

    /// §9 question 4, as a test. Whatever else changes, the screen is never taken silently
    /// while something cheaper is in contention.
    @Test func theScreenIsNeverTakenSilentlyWhileSomethingCheaperIsInContention() {
        for cheaper in [CapabilityRecord.Surface.headless, .opensApp] {
            let decision = CapabilityDecision.make(from: [
                hit("someapp.computerUse", 12.0, .takesScreen),
                hit("someapp.cheaper", 10.5, cheaper),
            ])
            if case .act(let acted) = decision {
                Issue.record("took \(acted.record.surface) silently over \(cheaper)")
            }
        }
    }

    /// A question that names nothing still answers in prose, whatever the surfaces are. The
    /// cost axis must not reintroduce the bug the whole agent document opens with.
    @Test func aQuestionThatNamesNothingIsStillProse() {
        #expect(CapabilityDecision.make(from: []) == .answer)
    }
}

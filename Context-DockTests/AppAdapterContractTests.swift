import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct AppAdapterContractTests {
    private func adapter(
        actions: [AdapterAction] = [], readers: [AdapterContextReader] = []
    ) -> AppAdapter {
        AppAdapter(
            id: "com.example.Editor", appName: "Editor", bundleId: "com.example.Editor",
            icon: "app", isBuiltIn: false, actions: actions, contextReaders: readers)
    }

    @Test func aWellFormedUserAdapterPassesTheSharedContract() {
        let value = adapter(
            actions: [AdapterAction(
                id: "editor.open", name: "Open", icon: "folder", type: .menubar,
                menuPath: ["File", "Open…"])],
            readers: [AdapterContextReader(
                id: "editor.document", name: "Current document", type: "jxa",
                script: "return 'document'")])
        #expect(AppAdapterContract.errors(in: value).isEmpty)
    }

    @Test func unsafeOrUnexecutableActionsAreRejectedBeforeInstall() {
        let value = adapter(actions: [
            AdapterAction(
                id: "editor.erase", name: "Erase", icon: "trash", type: .shell,
                script: "rm one-file", requiresApproval: false, isDestructive: true),
            AdapterAction(id: "editor.empty", name: "Empty", icon: "bolt", type: .urlScheme),
        ])
        let errors = AppAdapterContract.errors(in: value)
        #expect(errors.contains { $0.message.contains("must require approval") })
        #expect(errors.contains { $0.message.contains("no executable payload") })
    }

    @Test func brokenChainsDuplicateIDsAndReadersAreRejected() {
        let value = adapter(
            actions: [
                AdapterAction(id: "same", name: "One", icon: "1.circle", type: .aiPrompt,
                              aiPromptTemplate: "one", chain: ["missing"]),
                AdapterAction(id: "same", name: "Two", icon: "2.circle", type: .aiPrompt,
                              aiPromptTemplate: "two"),
            ],
            readers: [
                AdapterContextReader(id: "state", name: "State", type: "python", script: "x"),
                AdapterContextReader(id: "state", name: "Again", type: "shell", script: ""),
            ])
        let errors = AppAdapterContract.errors(in: value)
        #expect(errors.contains { $0.message.contains("Action ids must be unique") })
        #expect(errors.contains { $0.message.contains("does not exist") })
        #expect(errors.contains { $0.message.contains("Unknown context reader") })
        #expect(errors.contains { $0.message.contains("reader ids must be unique") })
    }
}

@MainActor
struct PriorityAdapterContractTests {
    @Test func personalDataAppsAlwaysGroundRecordQuestionsInLiveState() {
        let cases = [
            ("com.apple.mail", "anything unread?"),
            ("com.apple.iCal", "what is on tomorrow?"),
            ("com.apple.Notes", "what did i write recently?"),
            ("com.apple.reminders", "anything overdue?"),
            ("com.apple.MobileSMS", "who messaged me recently?"),
            ("com.apple.Photos", "show my recent photos"),
        ]
        for (bundleID, query) in cases {
            let decision = AgentSourceAuthority.decide(query: query, scopeBundleId: bundleID)
            #expect(decision.primary == .liveState, "\(bundleID) did not ground \(query)")
            #expect(!decision.allowsMemoryEvidence)
        }
    }

    @Test func priorityTypedCapabilitiesDeclareTheExpectedRisk() {
        let reads = [
            "calendar.next", "calendar.today", "calendar.list", "calendar.search",
            "photos.recent", "photos.search", "xcode.list", "xcode.showBuildSettings",
            "vscode.extensions.list", "github.list_issues", "github.list_prs", "github.get_repo",
        ]
        for id in reads {
            guard let capability = CapabilityRegistry.shared.capability(id: id) else {
                Issue.record("\(id) is not registered"); continue
            }
            #expect(!capability.riskLevel.requiresApproval, "\(id) is read-only")
        }
        for id in ["calendar.create", "calendar.update", "calendar.delete", "github.create_issue"] {
            guard let capability = CapabilityRegistry.shared.capability(id: id) else {
                Issue.record("\(id) is not registered"); continue
            }
            #expect(capability.riskLevel.requiresApproval, "\(id) changes external state")
        }
    }

    @Test func verifierCoverageIsExplicitAndInputBound() {
        #expect(ActionVerifierRegistry.registeredCapabilityIDs.contains("calendar.create"))
        #expect(ActionVerifierRegistry.registeredCapabilityIDs.contains("finder.trash"))
        #expect(ActionVerifierRegistry.descriptor(for: "github.create_issue") == nil)
        #expect(ActionVerifierRegistry.descriptor(for: "reminders.create")?.requiredInputKeys
            == ["title"])
    }

    @Test func evidenceCarriesScopeSourceFreshnessAndCompleteness() {
        let now = Date()
        let evidence = GroundedContextEvidence(
            readerID: "editor.current", source: "App Adapter · Current document",
            scopeBundleID: "com.example.Editor", capturedAt: now, text: "README.md",
            completeness: .complete)
        #expect(evidence.isUsable)
        #expect(evidence.scopeBundleID == "com.example.Editor")
        #expect(evidence.capturedAt == now)
    }

    @Test func appsWithoutTypedWritesCannotInventOne() {
        for bundleID in [
            "com.apple.Preview", "com.apple.Photos", "com.apple.dt.Xcode",
            "com.microsoft.VSCode", "com.spotify.client",
        ] {
            let writeCapabilities = CapabilityRegistry.shared.all.filter {
                $0.appBundleID == bundleID && $0.riskLevel.requiresApproval
            }
            #expect(writeCapabilities.isEmpty, "\(bundleID) unexpectedly exposes typed writes")
        }
    }
}

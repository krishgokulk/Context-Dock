import Testing
import Foundation
@testable import Context_Dock

// MARK: - U2a: General Chat scope isolation

@MainActor
struct GeneralChatScopeIsolationTests {

    @Test("appNeedingAccess returns nil for OS primitive read queries in General Chat")
    func osPrimitiveReadsSkipAppGate() {
        let result = AppScopedChatService.appNeedingAccess(
            query: "show me my reminders",
            scope: .general,
            attachedAppNames: [])
        #expect(result == nil)
    }

    @Test("appNeedingAccess returns nil for calendar read in General Chat")
    func calendarReadSkipsAppGate() {
        let result = AppScopedChatService.appNeedingAccess(
            query: "what's on my calendar today",
            scope: .general,
            attachedAppNames: [])
        #expect(result == nil)
    }

    @Test("appNeedingAccess returns nil for contacts read in General Chat")
    func contactsReadSkipsAppGate() {
        let result = AppScopedChatService.appNeedingAccess(
            query: "show me salman's phone number",
            scope: .general,
            attachedAppNames: [])
        #expect(result == nil)
    }

    @Test("appNeedingAccess returns nil for notes read in General Chat")
    func notesReadSkipsAppGate() {
        let result = AppScopedChatService.appNeedingAccess(
            query: "show me my notes about the launch",
            scope: .general,
            attachedAppNames: [])
        #expect(result == nil)
    }

    @Test("appNeedingAccess returns nil for screenshot read in General Chat")
    func screenshotReadSkipsAppGate() {
        let result = AppScopedChatService.appNeedingAccess(
            query: "show me my recent screenshots",
            scope: .general,
            attachedAppNames: [])
        #expect(result == nil)
    }
}

// MARK: - U2d: Screenshot routing

@MainActor
struct ScreenshotRoutingTests {

    @Test("screenshot queries route to .screenshots, not .photos")
    func screenshotRoutesToScreenshots() {
        #expect(ReadOnlyDataRouter.domain(for: "show me my screenshots") == .screenshots)
        #expect(ReadOnlyDataRouter.domain(for: "show me my recent screenshots") == .screenshots)
    }

    @Test("photo queries still route to .photos")
    func photosStillRouteToPhotos() {
        #expect(ReadOnlyDataRouter.domain(for: "show me my photos") == .photos)
        #expect(ReadOnlyDataRouter.domain(for: "show me my recent pictures") == .photos)
    }

    @Test("screenshots domain is an OS primitive")
    func screenshotsDomainIsOSPrimitive() {
        #expect(ReadOnlyDataDomain.screenshots.isOSPrimitive == true)
    }

    @Test("photos domain is not an OS primitive")
    func photosDomainIsNotOSPrimitive() {
        #expect(ReadOnlyDataDomain.photos.isOSPrimitive == false)
    }

    @Test("isOSPrimitive is true for calendar, reminders, contacts, notes")
    func osPrimitives() {
        #expect(ReadOnlyDataDomain.calendar.isOSPrimitive == true)
        #expect(ReadOnlyDataDomain.reminders.isOSPrimitive == true)
        #expect(ReadOnlyDataDomain.contacts.isOSPrimitive == true)
        #expect(ReadOnlyDataDomain.notes.isOSPrimitive == true)
    }

    @Test("isOSPrimitive is false for messages, mail")
    func nonPrimitives() {
        #expect(ReadOnlyDataDomain.messages.isOSPrimitive == false)
        #expect(ReadOnlyDataDomain.mail.isOSPrimitive == false)
    }
}

// MARK: - U2e: Capability call directive parsing

@MainActor
struct CapabilityCallDirectiveTests {

    @Test("knownCall parses capability_call JSON directive")
    func parsesCapabilityCall() {
        let text = """
            {"capability_call": {"capability_id": "finder.copyFiles", "source": "/a", "destination": "/b"}}
            """
        let call = ChatAnswerSanitizer.knownCall(in: text)
        #expect(call?.kind == "capability_call")
        #expect(call?.arguments["capability_id"] as? String == "finder.copyFiles")
    }

    @Test("capabilityIDCall parses dotted-id form")
    func parsesDottedIdCall() {
        let text = """
            {"finder.copyFiles": {"source": "/a", "destination": "/b"}}
            """
        let call = ChatAnswerSanitizer.capabilityIDCall(in: text)
        #expect(call?.id == "finder.copyFiles")
        #expect(call?.arguments["source"] as? String == "/a")
    }

    @Test("isProtocolOnly recognises capability_call as protocol")
    func capabilityCallIsProtocol() {
        let text = """
            {"capability_call": {"capability_id": "globalcmd.empty-trash"}}
            """
        #expect(ChatAnswerSanitizer.isProtocolOnly(text) == true)
    }

    @Test("isProtocolOnly recognises dotted-id form as protocol")
    func dottedIdIsProtocol() {
        #expect(ChatAnswerSanitizer.isProtocolOnly("{\"globalcmd.empty-trash\": {}}") == true)
    }
}

// MARK: - U2e: ChatCapabilityCallRecovery testable path

@MainActor
struct CapabilityCallRecoveryTests {

    @Test("unknown capability reports clearly")
    func unknownCapability() async {
        let outcome = await ChatCapabilityCallRecovery.run(
            capabilityID: "nonexistent.capability",
            arguments: [:],
            query: "do something",
            scope: .general,
            lookup: { _ in nil },
            execute: { (_: AIActionPlan) async throws -> AICapabilityExecutionResult in
                AICapabilityExecutionResult(success: false, output: "")
            })
        #expect(outcome.succeeded == false)
        #expect(outcome.text.contains("isn't a capability"))
    }

    @Test("missing required inputs are reported")
    func missingInputs() async {
        let outcome = await ChatCapabilityCallRecovery.run(
            capabilityID: "test.cap",
            arguments: [:],
            query: "do something",
            scope: .general,
            lookup: { _ in (title: "Test", requiredInputs: ["path"]) },
            execute: { (_: AIActionPlan) async throws -> AICapabilityExecutionResult in
                AICapabilityExecutionResult(success: true, output: "ok")
            })
        #expect(outcome.succeeded == false)
        #expect(outcome.text.contains("path"))
    }

    @Test("successful execution returns output")
    func successfulExecution() async {
        let outcome = await ChatCapabilityCallRecovery.run(
            capabilityID: "test.cap",
            arguments: ["path": "/tmp"],
            query: "do something",
            scope: .general,
            lookup: { _ in (title: "Test", requiredInputs: ["path"]) },
            execute: { (_: AIActionPlan) async throws -> AICapabilityExecutionResult in
                AICapabilityExecutionResult(success: true, output: "Done copying")
            })
        #expect(outcome.succeeded == true)
        #expect(outcome.text == "Done copying")
    }
}

// MARK: - U2f: Capability-based tool selection

@MainActor
struct CapabilityDerivedToolTests {

    @Test("impliedToolNames returns find_files for finder capabilities")
    func finderCapImpliesFindFiles() {
        let registry = CapabilityRegistry.shared
        let tools = registry.impliedToolNames(for: "com.apple.finder")
        #expect(tools.contains("find_files"))
    }

    @Test("impliedToolNames returns find_files for nil (global) scope")
    func globalCapImpliesFindFiles() {
        let tools = CapabilityRegistry.shared.impliedToolNames(for: nil)
        // Global file capabilities (finder.*) should imply find_files
        let allCaps = CapabilityRegistry.shared.capabilities(for: nil)
        let hasFileCap = allCaps.contains { $0.id.lowercased().contains("file") || $0.id.lowercased().hasPrefix("finder.") }
        if hasFileCap {
            #expect(tools.contains("find_files"))
        }
    }

    @Test("FrontmostAppTaskPlan no longer uses keyword matching for file tools")
    func noKeywordFalsePositiveForPassport() {
        // "passport" used to trigger find_files via fileTerms substring match.
        // Now tools are capability-derived, so an app without file capabilities
        // won't get find_files just because the query mentions "passport".
        let plan = FrontmostAppTaskPlan.make(
            query: "tell me about passport features",
            bundleId: "com.example.nonexistent",
            appName: "Example")
        // find_files should NOT be in the tool set for a random app with no file capabilities
        // (unless the app happens to have file capabilities registered)
        let allCaps = CapabilityRegistry.shared.capabilities(for: "com.example.nonexistent")
        let hasFileCap = allCaps.contains { $0.id.lowercased().contains("file") || $0.id.lowercased().hasPrefix("finder.") }
        if !hasFileCap {
            #expect(!plan.allowedToolNames.contains("find_files"))
        }
    }
}

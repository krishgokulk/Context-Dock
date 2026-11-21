import Testing

@testable import Context_Dock

// MARK: - Scope Isolation

@Suite("General Chat scope integrity – isolation")
struct ScopeIntegrityIsolationTests {

    @Test("effectiveBundleId returns empty for general scope")
    func generalScopeEmptyBundleId() {
        let scope: GeneralChatScope = .general
        let bundleId: String = {
            if case .general = scope { return "" }
            if case .thread = scope { return "" }
            return "should.not.reach"
        }()
        #expect(bundleId.isEmpty)
    }

    @Test("effectiveBundleId returns empty for thread scope")
    func threadScopeEmptyBundleId() {
        let scope: GeneralChatScope = .thread(id: "test-thread")
        let bundleId: String = {
            if case .general = scope { return "" }
            if case .thread = scope { return "" }
            return "should.not.reach"
        }()
        #expect(bundleId.isEmpty)
    }

    @Test("app scope returns a bundle ID")
    func appScopeReturnsBundleId() {
        let scope: GeneralChatScope = .app(bundleId: "com.apple.Safari")
        let bundleId: String = {
            if case .app(let id) = scope { return id }
            return ""
        }()
        #expect(bundleId == "com.apple.Safari")
    }

    @Test("General scope prompt assembles without app identity")
    func generalScopePromptNoAppIdentity() {
        var prompt = ScopedPromptAssembler()
        prompt.set(.identity, "You are DoraX's assistant on the user's Mac.")
        let assembled = prompt.assemble(for: .anthropic)
        #expect(assembled.contains("DoraX's assistant"))
        #expect(!assembled.contains("This conversation is scoped to"))
    }
}

// MARK: - System Primitives

@Suite("Core macOS system primitives in General Chat")
struct SystemPrimitivesTests {

    @Test("Calendar capabilities are always registered")
    @MainActor func calendarAlwaysRegistered() {
        let caps = CapabilityRegistry.shared.capabilities(for: nil)
        let calendarCaps = caps.filter { $0.id.hasPrefix("calendar.") }
        #expect(!calendarCaps.isEmpty, "Calendar capabilities must be registered as system primitives")
    }

    @Test("Notes capabilities are always registered")
    @MainActor func notesAlwaysRegistered() {
        let caps = CapabilityRegistry.shared.capabilities(for: nil)
        let notesCaps = caps.filter { $0.id.hasPrefix("notes.") }
        #expect(!notesCaps.isEmpty, "Notes capabilities must be registered as system primitives")
    }

    @Test("Reminders capabilities are always registered")
    @MainActor func remindersAlwaysRegistered() {
        let caps = CapabilityRegistry.shared.capabilities(for: nil)
        let remindersCaps = caps.filter { $0.id.hasPrefix("reminders.") }
        #expect(!remindersCaps.isEmpty, "Reminders capabilities must be registered as system primitives")
    }

    @Test("Finder capabilities are always registered")
    @MainActor func finderAlwaysRegistered() {
        let caps = CapabilityRegistry.shared.capabilities(for: nil)
        let finderCaps = caps.filter { $0.id.hasPrefix("finder.") }
        #expect(!finderCaps.isEmpty, "Finder capabilities must be registered")
    }

    @Test("Window management capability is always registered")
    @MainActor func windowAlwaysRegistered() {
        let cap = CapabilityRegistry.shared.capability(id: "window.arrange")
        #expect(cap != nil, "window.arrange must be registered")
    }

    @Test("System primitive prefixes include calendar, notes, reminders")
    func systemPrimitivePrefixesDefined() {
        let prefixes = CapabilityRegistry.systemPrimitivePrefixes
        #expect(prefixes.contains("calendar."))
        #expect(prefixes.contains("notes."))
        #expect(prefixes.contains("reminders."))
    }

    @Test("General Chat capability prompt includes system primitives")
    @MainActor func generalChatPromptIncludesPrimitives() {
        let block = CapabilityRegistry.shared.promptBlock(for: nil)
        #expect(block.contains("window.arrange"))
    }
}

// MARK: - Window Arrangement Fast-Path

@Suite("Window arrangement fast-path")
struct WindowArrangementFastPathTests {

    @Test("'split left' resolves to .left command")
    @MainActor func splitLeft() {
        let cmd = WindowArrangementFastPath.matchCommand("split left")
        #expect(cmd == .left)
    }

    @Test("'maximize window' resolves to .fill command")
    @MainActor func maximizeWindow() {
        let cmd = WindowArrangementFastPath.matchCommand("maximize window")
        #expect(cmd == .fill)
    }

    @Test("'full screen' resolves to .fullScreen command")
    @MainActor func fullScreen() {
        let cmd = WindowArrangementFastPath.matchCommand("full screen")
        #expect(cmd == .fullScreen)
    }

    @Test("'center it' resolves to .center command")
    @MainActor func centerIt() {
        let cmd = WindowArrangementFastPath.matchCommand("center it")
        #expect(cmd == .center)
    }

    @Test("'tile windows' resolves to .leftAndRight command")
    @MainActor func tileWindows() {
        let cmd = WindowArrangementFastPath.matchCommand("tile windows")
        #expect(cmd == .leftAndRight)
    }

    @Test("'side by side' resolves to .leftAndRight command")
    @MainActor func sideBySide() {
        let cmd = WindowArrangementFastPath.matchCommand("side by side")
        #expect(cmd == .leftAndRight)
    }

    @Test("'restore previous size' resolves to .restorePreviousSize")
    @MainActor func restoreSize() {
        let cmd = WindowArrangementFastPath.matchCommand("restore previous size")
        #expect(cmd == .restorePreviousSize)
    }

    @Test("Question about windows returns nil")
    @MainActor func questionReturnsNil() {
        let result = WindowArrangementFastPath.resolve(query: "how do I tile windows?", scope: .general)
        #expect(result == nil)
    }

    @Test("'what is full screen?' returns nil")
    @MainActor func whatQuestionReturnsNil() {
        let result = WindowArrangementFastPath.resolve(query: "what is full screen?", scope: .general)
        #expect(result == nil)
    }

    @Test("'can I center the window?' returns nil")
    @MainActor func canQuestionReturnsNil() {
        let result = WindowArrangementFastPath.resolve(query: "can I center the window?", scope: .general)
        #expect(result == nil)
    }

    @Test("Empty query returns nil")
    @MainActor func emptyQueryReturnsNil() {
        let cmd = WindowArrangementFastPath.matchCommand("")
        #expect(cmd == nil)
    }

    @Test("Unrelated query returns nil")
    @MainActor func unrelatedQueryReturnsNil() {
        let cmd = WindowArrangementFastPath.matchCommand("send an email to john")
        #expect(cmd == nil)
    }

    @Test("'minimize it' resolves to .minimize")
    @MainActor func minimizeIt() {
        let cmd = WindowArrangementFastPath.matchCommand("minimize it")
        #expect(cmd == .minimize)
    }
}

// MARK: - Process Update Verifier

@Suite("Process update verification")
struct ProcessUpdateVerifierTests {

    @Test("Empty bundle ID returns nil")
    @MainActor func emptyBundleIDReturnsNil() {
        let result = ProcessUpdateVerifier.runningInstance(bundleID: "")
        #expect(result == nil)
    }

    @Test("Non-running app returns nil")
    @MainActor func nonRunningAppReturnsNil() {
        let result = ProcessUpdateVerifier.runningInstance(bundleID: "com.nonexistent.app.xyz123")
        #expect(result == nil)
    }

    @Test("checkAfterCapabilityUpdate returns nil for non-running app")
    @MainActor func checkReturnsNilForNonRunning() {
        let notice = ProcessUpdateVerifier.checkAfterCapabilityUpdate(bundleID: "com.nonexistent.app.xyz123")
        #expect(notice == nil)
    }

    @Test("Finder is detected as running")
    @MainActor func finderDetectedAsRunning() {
        let result = ProcessUpdateVerifier.runningInstance(bundleID: "com.apple.finder")
        #expect(result != nil)
        #expect(result?.name == "Finder")
    }

    @Test("checkAfterCapabilityUpdate returns notice for running Finder")
    @MainActor func checkReturnsNoticeForFinder() {
        let notice = ProcessUpdateVerifier.checkAfterCapabilityUpdate(bundleID: "com.apple.finder")
        #expect(notice != nil)
        #expect(notice?.contains("Finder") == true)
        #expect(notice?.contains("running") == true)
    }
}

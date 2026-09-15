import Foundation
import Testing

@testable import Context_Dock

/// What a scoped chat is told to do when nothing linked fits the request.
///
/// Asked whether a newer VS Code exists, the Code chat answered that it could not check —
/// no update route linked, `code` only prints the installed version — and told the user to
/// add a route in Settings. Every sentence was true and the conclusion was wrong:
/// `run_command` exists, and `ArgvCommandGate` sends anything it does not recognise to the
/// approval path rather than refusing it. The model had a way to find out and was never
/// told it had one.
///
/// These pin the instruction, because the instruction is what produced the answer.
@MainActor
@Suite("Scoped prompt escape hatch")
struct ScopedPromptEscapeHatchTests {
    private func identityBlock(appName: String = "Code") -> String {
        ScopedAppPromptBuilder.appIdentityBlock(
            bundleId: "com.microsoft.VSCode",
            appName: appName,
            query: "is there a newer version available")
    }

    @Test func aDeadEndIsNeverTheLastWordWhenSomethingCouldBeRun() {
        let block = identityBlock()
        #expect(block.contains("run_command"))
        #expect(block.lowercased().contains("approval"))
    }

    /// The rung that was missing: propose the command, let the user approve it. Naming
    /// Settings is fine as an *addition*; it must not be the only offer.
    @Test func settingsAdviceIsNotTheOnlyOfferedRoute() throws {
        let block = identityBlock()
        let settingsLine = try #require(
            block.split(separator: "\n").first { $0.contains("Settings → App Adapters") })
        #expect(settingsLine.contains("propose") || settingsLine.contains("run_command"))
    }

    /// The model told the user a "Messages compose tool" was "not granted this session".
    /// No such per-session grant exists — the access gate returns its own text and a real
    /// enable button. Inventing a permission system teaches the user a rule that is not real.
    @Test func inventingPermissionStatesIsForbidden() {
        let block = identityBlock()
        #expect(block.lowercased().contains("never claim a tool is unavailable"))
    }
}

@MainActor
@Suite("Seeded basics migration")
struct SeededBasicsMigrationTests {
    @Test func generatedBasicsCarryTheApprovalRung() {
        let instructions = AdapterSkillSeeder.basicsInstructions(appName: "Code")
        #expect(instructions.contains("run_command"))
        #expect(instructions.lowercased().contains("approval"))
    }

    /// A user who edited their own skill keeps it. Migration is for text this app generated
    /// and still owns.
    @Test func theCurrentGeneratedTextIsRecognisedForMigration() {
        let previous = AdapterSkillSeeder.generatedBasicsV12(appName: "Code")
        #expect(AdapterSkillSeeder.isGeneratedBasics(previous, appName: "Code"))
        #expect(!AdapterSkillSeeder.isGeneratedBasics("My own notes about Code.", appName: "Code"))
    }
}

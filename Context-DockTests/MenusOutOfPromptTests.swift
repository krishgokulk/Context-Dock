import Foundation
import Testing

@testable import Context_Dock

/// P2 (plan §2a): menus come out of the default scoped prompt. The prompt no longer dumps
/// the app's menu bar — fifty paths that pushed the model to the interface before it looked
/// at the app's data. Menus are reached on demand with find_menu_command, and one tool
/// order, consistent with `CapabilityRecord.Surface`, is stated once.
@MainActor
@Suite("Menus out of the prompt")
struct MenusOutOfPromptTests {
    private func identityBlock(compact: Bool = false) -> String {
        ScopedAppPromptBuilder.appIdentityBlock(
            bundleId: "com.apple.Safari", appName: "Safari",
            query: "find mail from SBI today", compact: compact)
    }

    @Test func theDefaultPromptDoesNotDumpMenus() {
        for compact in [false, true] {
            let block = identityBlock(compact: compact)
            #expect(!block.contains("Available menu commands"))
            #expect(!block.contains("RUN one with the run_menu_command tool, passing the FULL"))
        }
    }

    @Test func menusAreReachableOnDemand() {
        // Full and compact both name the on-demand tool.
        #expect(identityBlock().contains("find_menu_command"))
        #expect(identityBlock(compact: true).contains("find_menu_command"))
    }

    /// One order, stated once, and it follows Surface cost: the headless rungs first, then
    /// the menu (opens the app), then Computer Use (drives the screen) last.
    @Test func oneToolOrderConsistentWithSurface() throws {
        let line = ScopedAppPromptBuilder.toolOrderLine
        #expect(identityBlock().contains(line))
        #expect(identityBlock(compact: true).contains(line))

        let adapter = try #require(line.range(of: "adapter action"))
        let menu = try #require(line.range(of: "menu command"))
        let screen = try #require(line.range(of: "operate_app"))
        #expect(adapter.lowerBound < menu.lowerBound)
        #expect(menu.lowerBound < screen.lowerBound)

        // Surface itself ranks these the same way, so prompt and cost model cannot drift.
        #expect(CapabilityRecord.Surface.headless < .opensApp)
        #expect(CapabilityRecord.Surface.opensApp < .takesScreen)
    }

    /// The menu tool is offered on an interface request and withheld on a plain question, so
    /// menus never crowd a turn that only asks about the app's content. (The finer data-vs-UI
    /// lane split for action verbs like "find" is P3; here the question shape is enough.)
    @Test func menuToolIsOfferedForUiRequestsOnly() {
        let ui = FrontmostAppTaskPlan.make(
            query: "minimize this window", bundleId: "com.apple.Safari", appName: "Safari")
        #expect(ui.allowedToolNames.contains("find_menu_command"))
        #expect(ui.allowedToolNames.contains("run_menu_command"))

        let question = FrontmostAppTaskPlan.make(
            query: "what did SBI email me today", bundleId: "com.apple.Mail", appName: "Mail")
        #expect(!question.allowedToolNames.contains("find_menu_command"))
    }
}

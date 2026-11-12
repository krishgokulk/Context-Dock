import Foundation
import Testing

@testable import Context_Dock

// MARK: - One job, one key; conflict order; staleness (H2 #409, spec §8 rules 4 and 6)

@Suite("LearnedSkillJob")
struct LearnedSkillJobTests {

    private let finder = "com.apple.finder"
    private let mail = "com.apple.mail"
    private let steps = [
        LearnedStep(text: "press menu File ▸ Compress"), LearnedStep(text: "click Button \"OK\""),
    ]

    private func computerUseRecipe(_ query: String, version: String = "1.0") -> AdapterSkill {
        ComputerUseSkillRecorder.makeSkill(
            bundleID: finder, appName: "Finder", goal: "whatever the model said", steps: steps,
            userQuery: query, appVersion: version)!
    }

    private func scriptRecipe(_ query: String, version: String = "1.0") -> AdapterSkill {
        AIScriptSkillRecorder.makeRecipe(
            command: "ls", success: true, bundleID: finder, appName: "Finder",
            userQuery: query, appVersion: version)!
    }

    private func solved(
        _ words: Set<String>, slots: [String] = [], capability: String = "finder.list",
        bundle: String? = nil
    ) -> SolvedSkill {
        SolvedSkill(
            queryTemplate: words.sorted().joined(separator: " "),
            nonSlotWords: words,
            slots: slots.map { SolvedSkillSlot(name: $0, tokenFamily: $0) },
            toolCalls: [
                SolvedSkillToolCall(capability: capability, argTemplate: [:], isReadOnly: true)
            ],
            bundleId: bundle ?? finder)
    }

    // MARK: Job key

    @Test func theKeyIsScopeAndSlotLiftedShape() throws {
        let context = SlotDerivationContext(selectedFilePaths: ["/tmp/report.pdf"])
        let one = try #require(
            LearnedSkillJob.key(query: "zip this", bundleId: finder, context: context))
        let other = try #require(
            LearnedSkillJob.key(
                query: "zip report.pdf", bundleId: finder,
                context: SlotDerivationContext(selectedFilePaths: ["/tmp/report.pdf"])))
        #expect(one == other)
        #expect(one == LearnedSkillJob.key(scope: finder, nonSlotWords: ["zip"], slotNames: ["file"]))
        // Another app, or another request, is another job.
        #expect(one != LearnedSkillJob.key(query: "zip this", bundleId: mail, context: context))
        #expect(one != LearnedSkillJob.key(query: "move this", bundleId: finder, context: context))
    }

    @Test func aSolvedSkillAndARecipeForOneRequestShareAKey() {
        let recipe = computerUseRecipe("unread mail today")
        let skill = solved(["unread", "mail"], slots: ["day"])
        #expect(recipe.jobKey == skill.jobKey)
        #expect(recipe.effectiveJobKey == skill.jobKey)
    }

    @Test func longRequestsThatShareTheirFirst48CharactersAreDifferentJobs() {
        let stem = "show every file in the downloads folder that is larger than"
        let a = computerUseRecipe(stem + " one gigabyte")
        let b = computerUseRecipe(stem + " ten megabytes")
        #expect(a.name == b.name)  // the old, name-only de-duplication merged these
        #expect(a.jobKey != b.jobKey)
        let both = LearnedSkillJob.merging(recipe: b, into: [a], solvedKeys: [])
        #expect(both?.count == 2)
    }

    @Test func aUserSkillClaimsAJobByItsName() {
        #expect(
            LearnedSkillJob.key(forSkillName: "Zip {file}", bundleId: finder)
                == LearnedSkillJob.key(scope: finder, nonSlotWords: ["zip"], slotNames: ["file"]))
    }

    @Test func aRecipeSavedBeforeH2KeepsItsJobAndRung() {
        let old = AdapterSkill(
            adapterBundleId: finder, name: "Learned: list desktop files", instructions: "steps")
        #expect(old.learnedRung == LearnedSkillJob.Rung.computerUse)
        #expect(old.effectiveJobKey == computerUseRecipe("list desktop files").jobKey)
        let user = AdapterSkill(adapterBundleId: finder, name: "My rules", instructions: "x")
        #expect(!user.isLearned)
    }

    // MARK: Conflict order — user or pack › solved › recipe

    @Test func aUserOrPackSkillBeatsARecipe() {
        let user = AdapterSkill(
            adapterBundleId: finder, name: "List desktop files", instructions: "mine")
        #expect(
            LearnedSkillJob.merging(
                recipe: computerUseRecipe("list desktop files"), into: [user], solvedKeys: [])
                == nil)
        // Turned off, it holds nothing.
        var off = user
        off.isEnabled = false
        #expect(
            LearnedSkillJob.merging(
                recipe: computerUseRecipe("list desktop files"), into: [off], solvedKeys: [])?
                .count == 2)
    }

    @Test func aUserOrPackSkillBeatsASolvedSkill() {
        let user = AdapterSkill(
            adapterBundleId: finder, name: "List desktop files", instructions: "mine")
        let skill = solved(["list", "desktop", "files"])
        let held = LearnedSkillJob.userHeldKeys(bundleId: finder, in: [user])
        #expect(held.contains(skill.jobKey))
        #expect(LearnedSkillJob.merging(solved: skill, into: [], userKeys: held) == nil)
    }

    @Test func aSolvedSkillBeatsARecipe() {
        let recipe = scriptRecipe("list desktop files")
        let skill = solved(["list", "desktop", "files"])
        // The recipe arrives second: dropped.
        #expect(
            LearnedSkillJob.merging(recipe: recipe, into: [], solvedKeys: [skill.jobKey]) == nil)
        // The solved skill arrives second: the recipe goes.
        let other = scriptRecipe("list downloads")
        let left = LearnedSkillJob.removingRecipes(
            jobKey: skill.jobKey, bundleId: finder, from: [recipe, other])
        #expect(left == [other])
    }

    // MARK: Conflict order — within learned skills

    @Test func aLowerRungRecipeReplacesAHigherOne() throws {
        let high = computerUseRecipe("list desktop files")  // rung 4
        let low = scriptRecipe("list desktop files")  // rung 2
        let merged = try #require(
            LearnedSkillJob.merging(recipe: low, into: [high], solvedKeys: []))
        #expect(merged.count == 1)
        #expect(merged[0].rung == LearnedSkillJob.Rung.script)
        #expect(merged[0].id == high.id)  // the same row in Settings
    }

    @Test func aHigherRungRecipeDoesNotReplaceALowerOne() {
        let low = scriptRecipe("list desktop files")
        let high = computerUseRecipe("list desktop files")
        #expect(LearnedSkillJob.merging(recipe: high, into: [low], solvedKeys: []) == nil)
    }

    @Test func aNewerSuccessOnTheSameRungReplacesTheOlder() throws {
        var old = scriptRecipe("list desktop files")
        old.instructions = "old command"
        old.isPinned = true
        old.isEnabled = false  // the user's choice, kept
        let new = scriptRecipe("list desktop files")
        let merged = try #require(
            LearnedSkillJob.merging(recipe: new, into: [old], solvedKeys: []))
        #expect(merged.count == 1)
        #expect(merged[0].instructions == new.instructions)
        #expect(merged[0].id == old.id)
        #expect(merged[0].isPinned)
        #expect(!merged[0].isEnabled)
    }

    @Test func solvedSkillsFollowTheSameRungOrder() throws {
        let direct = solved(["list", "desktop", "files"])  // rung 1
        let menu = solved(["list", "desktop", "files"], capability: "run_menu_command")  // rung 3
        #expect(direct.rung < menu.rung)
        // Higher rung does not replace a working lower one.
        #expect(LearnedSkillJob.merging(solved: menu, into: [direct], userKeys: []) == nil)
        // Lower replaces higher; same rung replaces older.
        #expect(LearnedSkillJob.merging(solved: direct, into: [menu], userKeys: []) == [direct])
        let newer = solved(["list", "desktop", "files"])
        #expect(LearnedSkillJob.merging(solved: newer, into: [direct], userKeys: []) == [newer])
        // Another app's skill with the same words is untouched.
        let elsewhere = solved(["list", "desktop", "files"], bundle: mail)
        #expect(
            LearnedSkillJob.merging(solved: newer, into: [elsewhere], userKeys: [])?.count == 2)
    }

    @Test func aSolvedSkillWhoseReplayFailedIsRepairedFromAnyRung() {
        var broken = solved(["list", "desktop", "files"])
        broken.consecutiveFailures = 1
        let menu = solved(["list", "desktop", "files"], capability: "run_menu_command")
        #expect(LearnedSkillJob.merging(solved: menu, into: [broken], userKeys: []) == [menu])
    }

    // MARK: Staleness

    @Test func anAppVersionChangeDisablesTheRecipe() throws {
        let recipe = scriptRecipe("list desktop files", version: "15.0")
        #expect(recipe.learnedAppVersion == "15.0")
        // Same version, an unreadable version, or another app: nothing happens.
        #expect(
            LearnedSkillJob.retiringVersionChanged(
                bundleId: finder, currentVersion: "15.0", in: [recipe]) == nil)
        #expect(
            LearnedSkillJob.retiringVersionChanged(
                bundleId: finder, currentVersion: "", in: [recipe]) == nil)
        #expect(
            LearnedSkillJob.retiringVersionChanged(
                bundleId: mail, currentVersion: "16.0", in: [recipe]) == nil)

        let user = AdapterSkill(adapterBundleId: finder, name: "Mine", instructions: "x")
        let retired = try #require(
            LearnedSkillJob.retiringVersionChanged(
                bundleId: finder, currentVersion: "15.1", in: [recipe, user]))
        #expect(!retired[0].isEnabled)
        #expect(retired[0].isStale)
        #expect(retired[1] == user)  // a user skill is never retired
    }

    @Test func twoFailuresInARowDisableTheRecipe() throws {
        let recipe = scriptRecipe("list desktop files")
        let once = try #require(
            LearnedSkillJob.notingFailure(jobKey: recipe.jobKey, bundleId: finder, in: [recipe]))
        #expect(once[0].isEnabled)
        #expect(once[0].consecutiveFailures == 1)
        let twice = try #require(
            LearnedSkillJob.notingFailure(jobKey: recipe.jobKey, bundleId: finder, in: once))
        #expect(!twice[0].isEnabled)
        #expect(twice[0].isStale)
        // A failure of some other job touches nothing.
        #expect(
            LearnedSkillJob.notingFailure(jobKey: "other", bundleId: finder, in: [recipe]) == nil)
    }

    @Test func aSuccessBetweenFailuresResetsTheCount() throws {
        let recipe = scriptRecipe("list desktop files")
        let once = try #require(
            LearnedSkillJob.notingFailure(jobKey: recipe.jobKey, bundleId: finder, in: [recipe]))
        let worked = try #require(
            LearnedSkillJob.merging(
                recipe: scriptRecipe("list desktop files"), into: once, solvedKeys: []))
        #expect(worked[0].consecutiveFailures == 0)
        let again = try #require(
            LearnedSkillJob.notingFailure(jobKey: recipe.jobKey, bundleId: finder, in: worked))
        #expect(again[0].isEnabled)
    }

    @Test func aRetiredRecipeIsRelearnedOnTheNextSuccess() throws {
        // Retired by version change, relearned from a HIGHER rung: relearning ignores rung.
        let low = scriptRecipe("list desktop files", version: "15.0")
        let retired = try #require(
            LearnedSkillJob.retiringVersionChanged(
                bundleId: finder, currentVersion: "15.1", in: [low]))
        let fresh = computerUseRecipe("list desktop files", version: "15.1")
        let relearned = try #require(
            LearnedSkillJob.merging(recipe: fresh, into: retired, solvedKeys: []))
        #expect(relearned.count == 1)
        #expect(relearned[0].id == low.id)
        #expect(relearned[0].isEnabled)
        #expect(!relearned[0].isStale)
        #expect(relearned[0].consecutiveFailures == 0)
        #expect(relearned[0].learnedAppVersion == "15.1")
        #expect(relearned[0].rung == LearnedSkillJob.Rung.computerUse)
        // And it is not retired again on the version it was relearned on.
        #expect(
            LearnedSkillJob.retiringVersionChanged(
                bundleId: finder, currentVersion: "15.1", in: relearned) == nil)
    }

    // MARK: Persistence

    @Test func skillsSavedBeforeH2StillDecode() throws {
        let adapter = try JSONDecoder().decode(
            AdapterSkill.self,
            from: Data(#"{"id":"a","adapterBundleId":"com.x","name":"N","instructions":"I"}"#.utf8))
        #expect(adapter.jobKey.isEmpty && adapter.rung == 0 && !adapter.isStale)
        #expect(adapter.learnedAppVersion.isEmpty && adapter.consecutiveFailures == 0)

        var old = solved(["list"])
        old.consecutiveFailures = nil
        let data = try JSONEncoder().encode(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("consecutiveFailures"))
        #expect(try JSONDecoder().decode(SolvedSkill.self, from: data) == old)

        let recipe = scriptRecipe("list desktop files", version: "2.0")
        let round = try JSONDecoder().decode(
            AdapterSkill.self, from: JSONEncoder().encode(recipe))
        #expect(round == recipe)
    }

    // MARK: Ladder instructions

    @Test func theLadderTellsTheModelToPreferAMatchingSkill() throws {
        let line = ScopedAppPromptBuilder.toolOrderLine
        let skill = try #require(line.range(of: "rung 0, a saved skill that matches"))
        let adapter = try #require(line.range(of: "adapter action"))
        #expect(skill.lowerBound < adapter.lowerBound)
        #expect(line.contains("skills.read"))
    }
}

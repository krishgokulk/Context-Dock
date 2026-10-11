import Foundation
import Testing

@testable import Context_Dock

/// The Creator's AI half: the prompt a model (or a person pasting into another AI) writes a
/// plugin from, how a reply becomes a manifest, and the validate-and-retry round.
struct PluginAuthoringTests {

    // MARK: The reference

    @Test func theReferenceNamesEveryComponentAndEveryBuiltIn() {
        let reference = PluginAuthoringPrompt.reference
        for component in PluginComponentCatalog.v1 {
            #expect(reference.contains("`\(component)`"), Comment(rawValue: component))
        }
        for builtIn in PluginSchema.builtInActionTypes {
            #expect(reference.contains("`\(builtIn)`"), Comment(rawValue: builtIn))
        }
        for input in PluginSchema.allowedInputs {
            #expect(reference.contains("`\(input)`"), Comment(rawValue: input))
        }
        // The two shipped plugins are the worked examples; a reference whose examples do
        // not validate teaches the wrong format.
        #expect(reference.contains("\"id\": \"currency\""))
        #expect(reference.contains("\"id\": \"sleep\""))
    }

    @Test func theExportablePromptCarriesTheRequestAndAsksForOneJSONBlock() {
        let prompt = PluginAuthoringPrompt.exportable(request: "a pomodoro timer in the strip")
        #expect(prompt.contains("a pomodoro timer in the strip"))
        #expect(prompt.contains("```json"))
        #expect(prompt.contains(PluginAuthoringPrompt.reference))
    }

    // MARK: Reading a reply

    @Test func aFencedBlockIsTheManifestAndTheLineBeforeItIsTheNote() throws {
        let reply = """
        Here is a timer that counts down in the bar.
        ```json
        { "id": "pomo", "name": "Pomodoro", "icon": "timer", "description": "x" }
        ```
        Change the length in `state`.
        """
        let read = try #require(PluginAuthoringReply.parse(reply))
        #expect(read.json.hasPrefix("{ \"id\": \"pomo\""))
        #expect(read.note == "Here is a timer that counts down in the bar.")
    }

    @Test func aBareObjectIsReadWithoutAFence() throws {
        let reply = """
        { "id": "a", "name": "A", "icon": "a.circle", "description": "" }
        """
        let read = try #require(PluginAuthoringReply.parse(reply))
        #expect(read.json.contains("\"id\": \"a\""))
        #expect(read.note.isEmpty)
    }

    @Test func proseWithNoObjectIsNotAManifest() {
        #expect(PluginAuthoringReply.parse("I cannot do that.") == nil)
        #expect(PluginAuthoringReply.parse("") == nil)
    }

    // MARK: The round

    @Test func aDraftThatValidatesIsReturnedInOneRound() async throws {
        var calls = 0
        let engine = PluginAuthoringEngine { _, _ in
            calls += 1
            return "A sleeper.\n```json\n\(PluginEssentials.sleepJSON)\n```"
        }
        let draft = try await engine.draft("put the mac to sleep", current: nil)
        #expect(calls == 1)
        #expect(draft.manifest?.id == "sleep")
        #expect(draft.note == "A sleeper.")
        #expect(draft.errors.isEmpty)
    }

    @Test func aDraftWithErrorsIsSentBackOnceWithThemAndTheFixWins() async throws {
        var seen: [String] = []
        let broken = """
        { "id": "x", "name": "X", "icon": "x", "description": "",
          "primaryAction": "missing" }
        """
        let engine = PluginAuthoringEngine { user, _ in
            seen.append(user)
            return seen.count == 1
                ? "```json\n\(broken)\n```"
                : "Fixed.\n```json\n\(PluginEssentials.sleepJSON)\n```"
        }
        let draft = try await engine.draft("sleep", current: nil)
        #expect(seen.count == 2)
        // The second turn carries what was wrong, so the model can act on it.
        #expect(seen[1].contains("primaryAction"))
        #expect(draft.manifest?.id == "sleep")
        #expect(draft.errors.isEmpty)
    }

    @Test func aReplyWithNoManifestTwiceIsAnError() async {
        let engine = PluginAuthoringEngine { _, _ in "I would rather not." }
        await #expect(throws: PluginAuthoringError.self) {
            _ = try await engine.draft("anything", current: nil)
        }
    }

    @Test func editingSendsTheCurrentManifestAlong() async throws {
        var seen = ""
        let engine = PluginAuthoringEngine { user, _ in
            seen = user
            return "```json\n\(PluginEssentials.sleepJSON)\n```"
        }
        _ = try await engine.draft("rename it to Nap", current: PluginEssentials.sleepJSON)
        #expect(seen.contains("\"id\": \"sleep\""))
        #expect(seen.contains("rename it to Nap"))
    }
}

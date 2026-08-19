import Testing
import Foundation
@testable import Context_Dock

// MARK: - Verification vocabulary
//
// These guard a distinction that was absent from the codebase until the control-plane
// audit: "the read-back disproved it" and "the read-back could not tell" were one value,
// so a trash that demonstrably failed and a windowed list that saw nothing produced the
// same sentence. The risk is not that the enum loses a case — it is that a later change
// quietly lets one of the three uncertain values claim success.

struct VerificationStatusTests {

    @Test func onlyVerifiedClaimsSuccess() {
        #expect(VerificationStatus.verified.claimsSuccess)
        #expect(!VerificationStatus.contradicted.claimsSuccess)
        #expect(!VerificationStatus.unverified.claimsSuccess)
        #expect(!VerificationStatus.notApplicable.claimsSuccess)
    }

    /// notApplicable is the value most likely to be "rounded up" by a later edit: the
    /// executor did report success, and only the absence of a verifier separates it from
    /// verified. It must stay separate.
    @Test func executorWordIsNotVerification() {
        #expect(VerificationStatus.notApplicable != .verified)
        #expect(!VerificationStatus.notApplicable.claimsSuccess)
    }

    @Test func everyStatusIsDistinguishableToTheUser() {
        let labels = Set(
            [VerificationStatus.verified, .contradicted, .unverified, .notApplicable]
                .map(\.chipLabel))
        #expect(labels.count == 4)
    }

    @Test func statusRoundTripsThroughCoding() throws {
        for status in [VerificationStatus.verified, .contradicted, .unverified, .notApplicable] {
            let data = try JSONEncoder().encode(status)
            #expect(try JSONDecoder().decode(VerificationStatus.self, from: data) == status)
        }
    }
}

// MARK: - Executor outcome → status

@MainActor
struct VerificationOutcomeMappingTests {

    typealias Outcome = GeneralAIActionExecutor.VerificationOutcome

    @Test func outcomesMapToTheirStatus() {
        #expect(Outcome.verified(nil).status == .verified)
        #expect(Outcome.verified("observed").status == .verified)
        #expect(Outcome.contradicted(evidence: "It's still at /tmp/x").status == .contradicted)
        #expect(Outcome.unverified(fallback: "couldn't see it").status == .unverified)
        #expect(Outcome.notApplicable.status == .notApplicable)
    }

    /// A contradiction carries the reading that disproved the write, because that reading is
    /// the only part the user can act on — it names where the thing still is.
    @Test func contradictionCarriesItsEvidence() {
        #expect(Outcome.contradicted(evidence: "It's still at /tmp/x").evidence
            == "It's still at /tmp/x")
        #expect(Outcome.unverified(fallback: "couldn't see it").evidence == "couldn't see it")
        #expect(Outcome.verified(nil).evidence == nil)
        #expect(Outcome.notApplicable.evidence == nil)
    }

    @Test func onlyVerifiedOutcomeClaimsSuccess() {
        let uncertain: [Outcome] = [
            .contradicted(evidence: "still there"),
            .unverified(fallback: "couldn't tell"),
            .notApplicable,
        ]
        for outcome in uncertain { #expect(!outcome.status.claimsSuccess) }
        #expect(Outcome.verified(nil).status.claimsSuccess)
    }
}

// MARK: - Turn record

@MainActor
struct GeneralChatWorkflowResultTests {

    /// The default matters: a record built without a verification argument describes a turn
    /// nobody read back, and defaulting to anything else would let silence claim success.
    @Test func verificationDefaultsToNoVerifier() {
        let result = GeneralChatWorkflowResult(answer: "done", route: .appMenu)
        #expect(result.verification == .notApplicable)
        #expect(!result.verification.claimsSuccess)
        #expect(result.executionRoute == nil)
    }

    /// Two axes, related in one place. Route cannot express an app launch or an API call, so
    /// the mechanism is carried rather than folded into the nearest classification.
    @Test func executionRoutesClassifyWithoutLosingTheMechanism() {
        #expect(GeneralChatWorkflowResult.Route.classifying(.verifiedMenu) == .appMenu)
        #expect(GeneralChatWorkflowResult.Route.classifying(.keyboardShortcut) == .appMenu)
        #expect(GeneralChatWorkflowResult.Route.classifying(.axFallback) == .appMenu)
        #expect(GeneralChatWorkflowResult.Route.classifying(.mcp) == .mcp)
        #expect(GeneralChatWorkflowResult.Route.classifying(.cli) == .cli)
        #expect(GeneralChatWorkflowResult.Route.classifying(.appLaunch) == .appAdapter)
        #expect(GeneralChatWorkflowResult.Route.classifying(.api) == .appAdapter)
        #expect(GeneralChatWorkflowResult.Route.classifying(.automation) == .appAdapter)
    }

    @Test func withAnswerKeepsEveryFact() {
        let receipt = DoraXActionReceipt(
            command: "adapter_action(finder.trash)", output: "Done", success: true)
        let original = GeneralChatWorkflowResult(
            answer: "",
            route: .appAdapter,
            executionRoute: .adapter,
            receipts: [receipt],
            verification: .contradicted)
        let phrased = original.withAnswer("That didn't take effect.")

        #expect(phrased.answer == "That didn't take effect.")
        #expect(phrased.route == original.route)
        #expect(phrased.executionRoute == original.executionRoute)
        #expect(phrased.verification == .contradicted)
        #expect(phrased.receipts == original.receipts)
    }
}

// MARK: - Receipt

struct DoraXActionReceiptTests {

    /// Runs written before the receipt was unified are still on disk. They carry no id and
    /// use these key names, so decoding them must keep working without a migration.
    @Test func decodesReceiptsWrittenBeforeTheTypeMoved() throws {
        let stored = """
            {"command":"run_command(ls)","output":"a\\nb","success":true,
             "isVerification":false,"recordedAt":"2026-08-15T10:04:23Z"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(
            DoraXActionReceipt.self, from: Data(stored.utf8))

        #expect(receipt.command == "run_command(ls)")
        #expect(receipt.output == "a\nb")
        #expect(receipt.success)
        #expect(!receipt.isVerification)
    }

    @Test func idIsNotPersisted() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            DoraXActionReceipt(command: "c", output: "o", success: true))
        let keys = Set((try JSONSerialization.jsonObject(with: data) as! [String: Any]).keys)
        #expect(keys == ["command", "output", "success", "isVerification", "recordedAt"])
    }

    /// Equality is content equality. Two instances describing the same observation are the
    /// same receipt — the id identifies a row in a list, not the fact it reports.
    @Test func equalityIgnoresInstanceIdentity() {
        let when = Date()
        let a = DoraXActionReceipt(
            command: "c", output: "o", success: true, recordedAt: when)
        let b = DoraXActionReceipt(
            command: "c", output: "o", success: true, recordedAt: when)
        #expect(a == b)
        #expect(a.id != b.id)
    }

    @Test func emptyOutputStillHasSomethingToDraw() {
        let receipt = DoraXActionReceipt(command: "c", output: "", success: true)
        #expect(receipt.observation == "No output")
    }
}

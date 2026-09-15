// VerificationStatus.swift
// Context-Dock
//
// Whether DoraX knows the thing it did actually happened.
//
// There were three vocabularies. The executor said verified / unverified / skipped, the
// turn contract said verified / executorConfirmed / unavailable / failed, and Context Dock
// Chat said nothing at all — it re-read the app into prose and recorded success
// unconditionally. Translating between them was lossy in both directions, and the loss
// always fell the same way: towards claiming more than was known.
//
// The case that was missing everywhere is `contradicted`. "The file is still at that path"
// and "I couldn't find it in Reminders just now" were the same value, so a trash that
// demonstrably failed and a read-back that simply could not see far enough produced the
// same sentence. They are not the same. One is proof the action did not land; the other is
// an absence of proof either way, and only one of them means the user should go and look.
//
// Nothing here decides whether a verifier ran well. It records what the verifier concluded,
// and refuses to let "we did not check" round up into "it worked".

import Foundation

enum VerificationStatus: String, Codable, Equatable {
    /// A read-back observed the outcome. This is the only value that earns a success claim.
    case verified

    /// A read-back observed the opposite: the write is provably not there. The file still
    /// exists, the app is not running, the reminder is still open. Stronger than a failure
    /// to confirm, and the user has somewhere specific to look.
    case contradicted

    /// A verifier ran and could not tell. The list it reads is windowed, the search it runs
    /// can miss, the window it compares settles on its own schedule. Absence of evidence.
    case unverified

    /// No verifier exists for this route. The executor's word is all there is, and saying so
    /// is the honest report — never a quiet promotion to `verified`.
    case notApplicable

    /// Whether the surface may state the outcome as done.
    ///
    /// Deliberately narrow. Three of four values mean DoraX does not know, and the three
    /// differ in what the user should do next, not in whether success may be claimed.
    var claimsSuccess: Bool { self == .verified }

    /// Short label for a chip beside the answer.
    var chipLabel: String {
        switch self {
        case .verified: return "Verified"
        case .contradicted: return "Did not land"
        case .unverified: return "Unconfirmed"
        case .notApplicable: return "Executor confirmed"
        }
    }
}

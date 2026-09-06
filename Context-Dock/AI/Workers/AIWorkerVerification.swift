import Foundation

/// Whether a worker's report survived contact with the machine.
///
/// The report is prose from an agent that ran somewhere else, and the difference between
/// "it says so" and "we checked" is the whole value of routing this through DoraX rather than
/// letting the user run the CLI themselves. The app already has the vocabulary —
/// `AIVerificationStatus` — so a delegated turn speaks it instead of inventing a second one.
enum AIWorkerVerification {
    /// One fact read back off the machine after the worker spoke.
    struct Reading: Equatable {
        /// What was read — "deployment target", "installed version", "git status".
        let subject: String
        /// What the machine said. Empty when the read failed.
        let value: String
        /// False when the read could not be taken at all, which is not evidence either way.
        let succeeded: Bool
    }

    struct Outcome: Equatable {
        let status: AIVerificationStatus
        /// What the user is told about the checking, in one line.
        let note: String
        let receipt: DoraXActionReceipt
    }

    static func assess(
        report: String,
        task: AIWorkerTask,
        readings: [Reading]
    ) -> Outcome {
        let usable = readings.filter(\.succeeded)

        let status: AIVerificationStatus
        let note: String

        if readings.isEmpty {
            // The worker ran and reported. Nothing was read back, so the honest word is that
            // its executor confirmed it — not that DoraX did.
            status = .executorConfirmed
            note = "Reported by the specialist. Nothing was read back to check it."
        } else if usable.isEmpty {
            status = .notAvailable
            note = "The check could not be taken, so this is unconfirmed either way."
        } else if let contradiction = usable.first(where: { !mentions($0.value, in: report) }) {
            // The case worth catching. A report the machine contradicts must not reach the
            // user wearing the same face as one it agrees with.
            status = .unverified
            note = "The report does not match what was read back: \(contradiction.subject) "
                + "is \(contradiction.value)."
        } else {
            status = .verified
            note = "Checked against the machine: "
                + usable.map { "\($0.subject) is \($0.value)" }.joined(separator: ", ") + "."
        }

        return Outcome(
            status: status,
            note: note,
            receipt: DoraXActionReceipt(
                command: "verify_worker_report(\(task.goal.prefix(60)))",
                output: note,
                success: status == .verified,
                isVerification: true))
    }

    /// Does the report actually contain what the machine said?
    ///
    /// Deliberately a containment check rather than a judgement about meaning: this decides
    /// whether to tell the user a claim was confirmed, and a fuzzy match here would be the app
    /// guessing on exactly the question the user is relying on it not to guess about.
    private static func mentions(_ value: String, in report: String) -> Bool {
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        return report.lowercased().contains(needle)
    }
}

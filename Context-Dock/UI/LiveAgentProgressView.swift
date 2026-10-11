import SwiftUI

/// Factual execution events shown while a turn runs. This is an activity timeline, not the
/// model's private reasoning: every row corresponds to an orchestrator or tool lifecycle event.
struct LiveAgentProgressView: View {
    let steps: [String]
    /// Rows recorded for this turn so far. When there are any they are the list — one per
    /// tool call, openable — and narration is reduced to the single live line beneath them.
    var activity: [ActivityStep] = []

    /// The line saying what is happening now, when no recorded step is itself running.
    private var liveLine: String? {
        guard !activity.contains(where: { $0.status == .running }) else { return nil }
        return uniqueSteps.last ?? "Working…"
    }

    private var uniqueSteps: [String] {
        var seen = Set<String>()
        return steps.filter {
            let key = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    var body: some View {
        if activity.isEmpty {
            narrationList
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(activity) { step in
                    ActivityStepRow(step: step)
                }
                if let liveLine {
                    HStack(alignment: .top, spacing: 6) {
                        ProgressView().controlSize(.mini).frame(width: 12).padding(.top, 1)
                        Text(liveLine)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var narrationList: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(uniqueSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    if index == uniqueSteps.count - 1 {
                        ProgressView().controlSize(.mini).padding(.top, 1)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                            .padding(.top, 1)
                    }
                    Text(step)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

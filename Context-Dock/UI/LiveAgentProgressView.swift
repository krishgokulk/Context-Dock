import SwiftUI

/// Factual execution events shown while a turn runs. This is an activity timeline, not the
/// model's private reasoning: every row corresponds to an orchestrator or tool lifecycle event.
struct LiveAgentProgressView: View {
    let steps: [String]

    private var uniqueSteps: [String] {
        var seen = Set<String>()
        return steps.filter {
            let key = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    var body: some View {
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

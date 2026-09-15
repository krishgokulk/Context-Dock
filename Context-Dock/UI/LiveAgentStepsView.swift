import SwiftUI

struct LiveAgentStepsView: View {
    let steps: [String]

    private var uniqueSteps: [String] {
        var seen = Set<String>()
        return steps.filter {
            let key = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    var body: some View {
        if !uniqueSteps.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label("\(uniqueSteps.count) step\(uniqueSteps.count == 1 ? "" : "s")", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(uniqueSteps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                            .padding(.top, 2)
                        Text(step)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

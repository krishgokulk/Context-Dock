import SwiftUI

/// The model's question, answerable by pointing.
///
/// Same row grammar as the `/` app list — one height, one highlight, one keyboard rule — so
/// the two lists read as one control with two sources rather than two designs for choosing
/// a thing in the same card.
///
/// "Something else" is not a fourth option. The options are what the model thought of; the
/// composer is what the user thought of, and the card must not imply the model's list is
/// exhaustive.
struct ChatClarificationCard: View {
    let clarification: ChatClarification
    /// Which row ↑/↓ has landed on. The list draws it; the surface owning the keyboard
    /// moves it, exactly as the slash list works.
    var selection: Int = 0
    let onChoose: (ChatClarification.Option) -> Void
    let onSomethingElse: () -> Void

    static let rowHeight: CGFloat = 34
    static let questionHeight: CGFloat = 30
    static let verticalInset: CGFloat = 6

    static func height(for optionCount: Int) -> CGFloat {
        guard optionCount > 0 else { return 0 }
        // Options, plus the "Something else" row, plus the question above them.
        return questionHeight + CGFloat(optionCount + 1) * rowHeight + verticalInset * 2
    }

    @State private var hovered: Int?

    private var selectedIndex: Int {
        guard !clarification.options.isEmpty else { return 0 }
        return min(max(selection, 0), clarification.options.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(clarification.question)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)

            ForEach(clarification.options) { option in
                Button { onChoose(option) } label: {
                    HStack(spacing: 10) {
                        Text("\(option.index)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.secondary.opacity(0.16)))

                        Text(option.label)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        if option.index - 1 == selectedIndex {
                            Text("↩")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: Self.rowHeight)
                    .background(
                        tint(for: option.index - 1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? option.index - 1 : nil }
                .accessibilityLabel("Option \(option.index): \(option.label)")
            }

            Button(action: onSomethingElse) {
                HStack(spacing: 10) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                    Text("Something else")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 14)
                .frame(height: Self.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Answer in your own words")
        }
        .padding(.vertical, Self.verticalInset)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08)))
    }

    private func tint(for index: Int) -> Color {
        if index == selectedIndex { return Color.accentColor.opacity(0.22) }
        if index == hovered { return Color.secondary.opacity(0.12) }
        return .clear
    }
}

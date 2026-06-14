import SwiftUI

struct SelectionShortcutSurface: View {
    @State var shortcuts: [ShortcutAction] = []
    @State var selectedIndex: Int? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { offset, shortcut in
                    ShortcutActionRow(
                        action: shortcut,
                        isSelected: selectedIndex == offset
                    )
                    .onTapGesture {
                        selectedIndex = offset
                        shortcut.execute()
                    }
                }

                if shortcuts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bolt.slash")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text("No matching shortcuts")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }
            .padding(8)
        }
    }
}

struct ShortcutAction {
    let id: String
    let title: String
    let icon: String
    let execute: () -> Void
}

struct ShortcutActionRow: View {
    let action: ShortcutAction
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: action.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(action.title)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(4)
    }
}

import SwiftUI

struct ContextDockSurface: View {
    @StateObject var viewModel = ContextDockViewModel()
    @State var selectedIndex: Int? = nil
    @State var focusedPillID: String? = nil
    @State var results: [SearchResult] = []

    var body: some View {
        VStack(spacing: 0) {
            // Result list
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(results.enumerated()), id: \.offset) { offset, result in
                        ResultRow(
                            result: result,
                            isSelected: selectedIndex == offset,
                            isPinned: false
                        )
                        .onTapGesture {
                            selectedIndex = offset
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 200)

            Divider()

            // Pills/dock
            HStack(spacing: 6) {
                Text("Pills go here")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

struct DockPillView: View {
    let pill: DockPill
    let isFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            if let image = pill.menuItemImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .cornerRadius(4)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            Text(pill.name)
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .padding(6)
        .background(isFocused ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(6)
    }
}

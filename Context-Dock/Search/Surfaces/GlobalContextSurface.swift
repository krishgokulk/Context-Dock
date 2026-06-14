import SwiftUI

struct GlobalContextSurface: View {
    let results: [SearchResult]
    let query: String
    @State var selectedIndex: Int? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if results.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("Global Context")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    ForEach(Array(results.enumerated()), id: \.offset) { offset, result in
                        ResultRow(
                            result: result,
                            isSelected: selectedIndex == offset,
                            isPinned: false
                        )
                        .onTapGesture {
                            selectedIndex = offset
                            result.action()
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

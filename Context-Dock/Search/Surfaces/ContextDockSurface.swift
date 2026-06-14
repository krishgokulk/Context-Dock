import SwiftUI

struct ContextDockSurface: View {
    @EnvironmentObject var contextEnv: ContextDockEnvironment
    @State var selectedResultIndex: Int? = nil

    // Receive data from parent
    var results: [SearchResult] = []
    var query: String = ""
    var dockPills: [DockPill] = []

    var body: some View {
        VStack(spacing: 0) {
            // Result list (only show if not typing dock pills)
            if !results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(results.enumerated()), id: \.offset) { offset, result in
                            ResultRow(
                                result: result,
                                isSelected: selectedResultIndex == offset,
                                isPinned: false
                            )
                            .onTapGesture {
                                selectedResultIndex = offset
                                result.action()
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 200)

                Divider()
            }

            // Pills/dock (frontmost app context)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(dockPills, id: \.id) { pill in
                        DockPillContainer(pill: pill)
                            .onTapGesture {
                                pill.execute()
                            }
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }
}

struct DockPillContainer: View {
    let pill: DockPill

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
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            Text(pill.name)
                .font(.system(size: 9))
                .lineLimit(1)
                .frame(width: 40)
        }
        .frame(width: 48, height: 56)
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

import SwiftUI
import Combine

struct UnifiedDockShell: View {
    @Binding var isVisible: Bool
    @StateObject var modeObserver = dockModeObserver
    @State private var windowHeight: CGFloat = 250

    var results: [SearchResult] = []
    var query: String = ""
    var dockPills: [DockPill] = []

    var body: some View {
        VStack(spacing: 0) {
            DockHeader()
            DockInputBar()
            DockContextChips()
            DockContentArea(
                mode: modeObserver.activeMode,
                dockPills: dockPills,
                results: results,
                query: query
            )
        }
        .frame(height: windowHeight)
        .background(DockBackground())
        .onReceive(modeObserver.modePublisher) { mode in
            withAnimation(.easeOut(duration: 0.12)) {
                modeObserver.activeMode = mode
                updateWindowHeight(for: mode)
            }
        }
    }

    private func updateWindowHeight(for mode: DockMode) {
        let baseHeight: CGFloat = 110
        let contentHeight: CGFloat = contentHeightForMode(mode)
        windowHeight = baseHeight + contentHeight
    }

    private func contentHeightForMode(_ mode: DockMode) -> CGFloat {
        switch mode {
        case .globalContext: return 150
        case .contextDock: return 200
        case .generalChat: return 300
        case .contextDockChat: return 280
        case .mediaDock: return 120
        case .selectionShortcut: return 180
        }
    }
}

enum DockMode {
    case globalContext
    case contextDock
    case generalChat
    case contextDockChat
    case mediaDock
    case selectionShortcut
}

struct DockHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Context Dock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
                .font(.system(size: 14))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct DockInputBar: View {
    @State var query: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search or ask", text: $query)
                .textFieldStyle(.plain)
            Button(action: {}) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct DockContextChips: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(["file.txt", "selected text", "Mail"], id: \.self) { chip in
                Text(chip)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(4)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct DockContentArea: View {
    let mode: DockMode
    var dockPills: [DockPill] = []
    var results: [SearchResult] = []
    var query: String = ""

    var body: some View {
        ZStack {
            switch mode {
            case .globalContext:
                GlobalContextSurface(results: results, query: query)
            case .contextDock:
                ContextDockSurface(results: results, query: query)
            case .generalChat:
                GeneralChatSurface()
            case .contextDockChat:
                ContextDockChatSurface()
            case .mediaDock:
                MediaDockSurface()
            case .selectionShortcut:
                SelectionShortcutSurface()
            }
        }
    }
}

struct DockBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: NSColor(calibratedHue: 0.6, saturation: 0.05, brightness: 0.95, alpha: 0.95))
        }
        .ignoresSafeArea()
    }
}


class DockModeObserver: ObservableObject {
    @Published var activeMode: DockMode = .globalContext
    let modePublisher = PassthroughSubject<DockMode, Never>()
}

let dockModeObserver = DockModeObserver()

#if DEBUG
import AppKit
import Combine
import SwiftUI

/// One shared, non-activating panel showing what the registry knows about the locked region.
///
/// Non-activating because reading it must not take key status from the surface being
/// inspected. A panel that steals focus changes the very state a developer opened it to look
/// at, and a chat surface that loses first responder mid-inspection reports the wrong thing.
@MainActor
final class InspectorDetailPanelController {
    private let panel: NSPanel
    private let model = InspectorDetailModel()

    init() {
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 210),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "DoraX Inspector"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: InspectorDetailView(model: model))
    }

    func present(registration: InspectRegistration, ordinal: Int?, isExactRegion: Bool) {
        model.id = registration.key.id.rawValue
        model.ordinal = ordinal
        model.source = "\(registration.source.file):\(registration.source.line)"
        model.type = registration.source.type
        model.frame = registration.frameInWindowRoot
        model.windowID = registration.key.windowID.rawValue
        model.precision = isExactRegion ? "Exact instrumented region" : "Nearest instrumented ancestor"

        if !panel.isVisible {
            panel.center()
        }
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }
}

@MainActor
final class InspectorDetailModel: ObservableObject {
    @Published var id = ""
    @Published var ordinal: Int?
    @Published var source = ""
    @Published var type = ""
    @Published var frame = CGRect.zero
    @Published var windowID = 0
    @Published var precision = ""
}

private struct InspectorDetailView: View {
    @ObservedObject var model: InspectorDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(model.ordinal.map { "\(model.id) #\($0)" } ?? model.id)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)

            row("Source", model.source)
            row("Type", model.type)
            row(
                "Frame",
                String(
                    format: "x %.0f  y %.0f  w %.0f  h %.0f",
                    model.frame.minX, model.frame.minY, model.frame.width, model.frame.height
                )
            )
            row("Window", "\(model.windowID)")
            row("Precision", model.precision)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
#endif

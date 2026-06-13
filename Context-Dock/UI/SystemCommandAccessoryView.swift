// SystemCommandAccessoryView.swift
// Context-Dock
//
// Inline live control rendered on the trailing edge of a system-command row:
//   [icon] Volume  ────────○──  65
//   [icon] Wi-Fi Power            (toggle)
//
// Slider changes are debounced (~90ms) so dragging doesn't spawn a process per
// pixel; toggles fire immediately. Both run silently through
// SystemCommandInteractiveRunner with the value injected as CD_QUERY.

import SwiftUI

struct SystemCommandAccessoryView: View {
    let command: SystemCommand

    @ObservedObject private var state = InteractiveCommandState.shared
    @State private var dragValue: Double?
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch command.interactionType {
            case .slider:
                sliderBody
            case .toggle:
                toggleBody
            case .none:
                EmptyView()
            }
        }
        .onAppear { state.refreshIfNeeded(command) }
    }

    // MARK: - Slider

    private var sliderBody: some View {
        let range = command.sliderMin...max(command.sliderMax, command.sliderMin + 1)
        let binding = Binding<Double>(
            get: { dragValue ?? state.value(for: command) ?? command.sliderMin },
            set: { newValue in
                dragValue = newValue
                debounceTask?.cancel()
                debounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 90_000_000)
                    guard !Task.isCancelled else { return }
                    commitSlider(newValue)
                }
            }
        )
        return HStack(spacing: 8) {
            Slider(value: binding, in: range, step: max(command.sliderStep, 0.0001))
                .controlSize(.small)
                .frame(width: 140)
            Text("\(Int(binding.wrappedValue.rounded()))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func commitSlider(_ value: Double) {
        state.setLocal(value, for: command.id)
        dragValue = nil
        SystemCommandInteractiveRunner.run(command, value: String(Int(value.rounded())))
    }

    // MARK: - Toggle

    private var toggleBody: some View {
        Toggle(
            "",
            isOn: Binding(
                get: { (state.value(for: command) ?? 0) >= 0.5 },
                set: { isOn in
                    state.setLocal(isOn ? 1 : 0, for: command.id)
                    SystemCommandInteractiveRunner.run(command, value: isOn ? "on" : "off")
                }
            )
        )
        .toggleStyle(.switch)
        .controlSize(.small)
        .labelsHidden()
    }
}

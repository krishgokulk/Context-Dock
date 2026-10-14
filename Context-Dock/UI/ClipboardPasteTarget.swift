import AppKit
import SwiftUI

/// An app a clip selection can be pasted into. Plain values, so the order is tested without
/// running apps; the app itself is looked up by pid when the paste happens.
struct ClipboardPasteTarget: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    var id: pid_t { pid }

    /// The app the user came from first — it is where a plain Return would have gone — then
    /// every other app the user can see, by name. Never this app, never the same pid twice.
    static func ordered(
        _ apps: [ClipboardPasteTarget], frontPID: pid_t?, excluding selfBundleID: String?
    ) -> [ClipboardPasteTarget] {
        var seen = Set<pid_t>()
        let candidates = apps.filter {
            $0.bundleID != selfBundleID && seen.insert($0.pid).inserted
        }
        let front = candidates.filter { $0.pid == frontPID }
        let rest = candidates.filter { $0.pid != frontPID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return front + rest
    }

    /// The running apps with a Dock presence, in the order a picker shows them.
    @MainActor
    static func running(frontPID: pid_t?) -> [ClipboardPasteTarget] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map {
                ClipboardPasteTarget(
                    pid: $0.processIdentifier, name: $0.localizedName ?? "App",
                    bundleID: $0.bundleIdentifier)
            }
        return ordered(apps, frontPID: frontPID, excluding: Bundle.main.bundleIdentifier)
    }
}

/// ⌘↩ with several clips picked: where should they go? Open over the board's foot until an
/// app is chosen or Esc.
struct ClipboardTargetPicker {
    var entries: [DockCore.ClipboardEntry]
    var targets: [ClipboardPasteTarget]
    var index = 0

    mutating func move(_ step: Int) {
        guard !targets.isEmpty else { return }
        index = min(max(index + step, 0), targets.count - 1)
    }

    var chosen: ClipboardPasteTarget? { targets.indices.contains(index) ? targets[index] : nil }
}

struct ClipboardTargetPickerView: View {
    let picker: ClipboardTargetPicker
    let onChoose: (ClipboardPasteTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Paste \(picker.entries.count) clips to…")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(Array(picker.targets.enumerated()), id: \.element.id) { i, target in
                            row(target, selected: i == picker.index)
                                .id(target.id)
                                .onTapGesture { onChoose(target) }
                        }
                    }
                }
                .frame(maxHeight: 6 * 30)
                .onChange(of: picker.index) { _, i in
                    if let t = picker.targets[safe: i] { proxy.scrollTo(t.id) }
                }
            }
        }
        .padding(6)
        .frame(width: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private func row(_ target: ClipboardPasteTarget, selected: Bool) -> some View {
        HStack(spacing: 8) {
            if let app = NSRunningApplication(processIdentifier: target.pid), let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            }
            Text(target.name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 0)
            if selected {
                BoardFooter.keycaps(["↩"])
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.14 : 0)))
        .contentShape(Rectangle())
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

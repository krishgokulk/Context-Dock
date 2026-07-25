import Foundation
import SwiftUI
import Combine

/// Keeps an app-scoped CLI unavailable to the AI until the user has explicitly
/// chosen how it may be used. Existing extensions keep their historical behaviour;
/// only extensions added after this gate was introduced are marked pending.
@MainActor
final class AppCLIAgentConsentStore: ObservableObject {
    static let shared = AppCLIAgentConsentStore()

    enum Decision: String, Codable {
        case pending
        case allowed
        case denied
        case remindLater
    }

    struct Record: Codable {
        var decision: Decision
        var remindAfter: Date?
    }

    @Published private var records: [String: Record] = [:]
    private let defaultsKey = "AppCLIAgentConsentRecords"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return }
        records = decoded
    }

    func markPending(for ext: AppToolExtension) {
        guard ext.kind == .cli else { return }
        records[ext.id.uuidString] = Record(decision: .pending, remindAfter: nil)
        save()
    }

    func isAllowed(_ ext: AppToolExtension) -> Bool {
        guard ext.kind == .cli else { return true }
        // No record means this was an extension from before the consent gate.
        return records[ext.id.uuidString]?.decision != .pending
            && records[ext.id.uuidString]?.decision != .remindLater
            && records[ext.id.uuidString]?.decision != .denied
    }

    func nextPrompt(for appKey: String) -> AppToolExtension? {
        let now = Date()
        return AppSettings.shared.toolExtensions(for: appKey).first { ext in
            guard ext.kind == .cli, let record = records[ext.id.uuidString] else { return false }
            switch record.decision {
            case .pending: return true
            case .remindLater: return (record.remindAfter ?? .distantPast) <= now
            case .allowed, .denied: return false
            }
        }
    }

    func allow(_ ext: AppToolExtension) { set(.allowed, for: ext) }
    func deny(_ ext: AppToolExtension) { set(.denied, for: ext) }

    func remindLater(_ ext: AppToolExtension) {
        records[ext.id.uuidString] = Record(
            decision: .remindLater,
            remindAfter: Calendar.current.date(byAdding: .day, value: 1, to: Date()))
        save()
    }

    private func set(_ decision: Decision, for ext: AppToolExtension) {
        records[ext.id.uuidString] = Record(decision: decision, remindAfter: nil)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// Inline first-use choice shown before an app chat can offer a newly-added CLI
/// to its AI agent. This is intentionally separate from command approval: it is
/// permission to *suggest/use this tool for this app*, not permission to run one
/// particular command.
struct AppCLIAgentConsentCard: View {
    let tool: AppToolExtension
    @ObservedObject private var consent = AppCLIAgentConsentStore.shared

    private var isResolved: Bool { consent.nextPrompt(for: tool.appKey)?.id != tool.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.badge.shield")
                    .foregroundStyle(.green)
                Text(isResolved ? "CLI access updated" : "New CLI tool added")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("\(tool.toolName) was added for \(tool.appKey.capitalized). May this app's AI agent use it when it helps answer your requests?")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if isResolved {
                Text("Your choice is saved. You can change this by removing and adding the tool again.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Button("Yes, allow") { consent.allow(tool) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("No") { consent.deny(tool) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Remind later") { consent.remindLater(tool) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.green.opacity(0.28), lineWidth: 0.75))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ClaudeSubscriptionConfigView.swift
// Context-Dock
//
// Settings for the provider that has nothing to configure.
//
// There is no endpoint, no port, no API key and no model name to type — the three fields
// that made the bridge panel fragile. Either the Claude CLI is on this Mac and signed in, or
// it is not, and this screen's whole job is to say which and how to fix it.

import SwiftUI

struct ClaudeSubscriptionConfigView: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var state: State = .checking
    @State private var probeMessage: String?

    enum State: Equatable {
        case checking
        case ready(path: String)
        case missing
        case verifying
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statusCard

            if case .missing = state {
                installHelp
            } else {
                modelPicker
                accessPicker
                verifyRow
            }
        }
        .task { refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Subscription").font(.headline)
                Text("Your Pro or Max plan, used directly. No proxy, no API key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Check again")
        }
    }

    @ViewBuilder private var statusCard: some View {
        HStack(alignment: .top, spacing: 10) {
            switch state {
            case .checking:
                ProgressView().scaleEffect(0.6)
                Text("Looking for Claude Code…").font(.caption).foregroundStyle(.secondary)
            case .ready(let path):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready").font(.subheadline).fontWeight(.medium)
                    Text(path).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            case .missing:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text("Claude Code isn't installed on this Mac.").font(.caption)
            case .verifying:
                ProgressView().scaleEffect(0.6)
                Text("Asking Claude to reply…").font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var installHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Two steps, once:").font(.caption).fontWeight(.medium)
            Label("Install Claude Code", systemImage: "1.circle")
                .font(.caption)
            Text("curl -fsSL https://claude.ai/install.sh | bash")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            Label("Run `claude` in a terminal and sign in", systemImage: "2.circle")
                .font(.caption)
            Text("Signing in there is what links your subscription. DoraX never sees the "
                + "credentials — it runs the CLI you already trust.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Aliases, not pinned versions. The CLI resolves these to whatever its current release
    /// maps them to, so a model retired upstream cannot strand this setting the way a typed
    /// model id stranded the bridge.
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(.subheadline).fontWeight(.medium)
            Picker("", selection: $settings.claudeCodeModel) {
                Text("Default (whatever your plan gives)").tag("")
                Text("Opus — most capable").tag("opus")
                Text("Sonnet — faster").tag("sonnet")
                Text("Haiku — fastest").tag("haiku")
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    /// What the CLI is allowed to do on this Mac.
    ///
    /// Visible rather than assumed: above "Answer only" the CLI runs its own tools under its
    /// own permission model, and none of DoraX's approval prompts apply to it. Someone turning
    /// that on should be able to see that they did.
    private var accessPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What Claude may do").font(.subheadline).fontWeight(.medium)
            Picker("", selection: $settings.claudeCodeToolAccessRaw) {
                ForEach(ClaudeCodeCLIService.ToolAccess.allCases, id: \.rawValue) { access in
                    Text(access.title).tag(access.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Text(settings.claudeCodeToolAccess.detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.claudeCodeToolAccess.runsTools {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: settings.claudeCodeToolAccess == .full
                        ? "exclamationmark.triangle.fill" : "folder")
                        .foregroundStyle(settings.claudeCodeToolAccess == .full ? .orange : .secondary)
                    Text("Working folder: \(ChatWorkingDirectory.resolve(for: nil).path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var verifyRow: some View {
        HStack(spacing: 10) {
            Button("Send a test message") {
                Task { await verify() }
            }
            .buttonStyle(.bordered)
            .disabled(state == .verifying)

            if let probeMessage {
                Text(probeMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        probeMessage = nil
        state = ClaudeCodeCLIService.binaryPath().map(State.ready) ?? .missing
    }

    /// A real round trip. "Installed" and "signed in" are different facts, and only asking
    /// tells them apart — the binary is present either way.
    private func verify() async {
        state = .verifying
        probeMessage = nil
        do {
            let reply = try await ClaudeCodeCLIService.send(
                prompt: "Reply with exactly: ready",
                systemPrompt: nil,
                model: settings.claudeCodeModel.isEmpty ? nil : settings.claudeCodeModel)
            refresh()
            probeMessage = "Answered: \(reply.prefix(40))"
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

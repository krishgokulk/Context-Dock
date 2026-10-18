import SwiftUI

struct ChatGPTSubscriptionConfigView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var models: [CodexCLIService.SubscriptionModel] = []
    @State private var status = "Checking Codex sign-in…"
    @State private var ready = false
    @State private var busy = false
    @State private var probe: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AIProviderIcon(provider: .chatGPTSubscription, size: 26)
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ChatGPT Subscription").font(.headline)
                    Text("Your ChatGPT plan through Codex. No API key or separate API billing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { startRefresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Check install, sign-in and available models")
                    .disabled(busy)
            }
            HStack(alignment: .top, spacing: 10) {
                if busy { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ready ? .green : .orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(status).font(.caption).fixedSize(horizontal: false, vertical: true)
                    if let path = CodexCLIService.binaryPath() {
                        Text(path).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

            if !ready && !busy { setupHelp }

            if !models.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model").font(.subheadline).fontWeight(.medium)
                    Picker("Model", selection: $settings.chatGPTSubscriptionModel) {
                        Text("Default (Codex chooses for your plan)").tag("")
                        ForEach(models) { model in Text(model.name).tag(model.id) }
                        if !settings.chatGPTSubscriptionModel.isEmpty,
                           !models.contains(where: { $0.id == settings.chatGPTSubscriptionModel }) {
                            Text("Unavailable: \(settings.chatGPTSubscriptionModel)")
                                .tag(settings.chatGPTSubscriptionModel)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).disabled(busy)
                    Text("Models come from your signed-in Codex account. Plan limits apply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What ChatGPT may do").font(.subheadline).fontWeight(.medium)
                Text("DoraX handles app actions and approval cards. Codex’s own shell, web tools, "
                     + "connectors and plugins are disabled for this provider.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Cloud-backed: prompts and the context you share are sent to OpenAI.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Send a test message") { startTest() }
                    .buttonStyle(.bordered).disabled(busy || !ready)
                if busy {
                    Button("Cancel") {
                        operation?.cancel()
                        operation = nil
                        busy = false
                        status = "Cancelled. Check again when ready."
                    }
                }
                if let probe {
                    Text(probe).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { startRefresh() }
        .onDisappear { operation?.cancel() }
    }

    private var setupHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In Terminal, once:").font(.caption).fontWeight(.medium)
            Text("brew install --cask codex\ncodex login")
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            Text("Choose Sign in with ChatGPT. If Codex is already installed, only sign in. "
                 + "DoraX checks the CLI’s account status; it never reads or stores your credentials.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func startRefresh() {
        operation?.cancel()
        busy = true
        ready = false
        probe = nil
        status = "Checking Codex sign-in…"
        operation = Task { @MainActor in
            defer { if !Task.isCancelled { busy = false } }
            guard CodexCLIService.binaryPath() != nil else {
                models = []
                status = "Codex isn’t installed on this Mac."
                return
            }
            do {
                let catalog = try await CodexCLIService.subscriptionModels()
                try Task.checkCancellation()
                models = catalog
                ready = true
                status = "Signed in with ChatGPT · Ready"
            } catch is CancellationError { return }
            catch {
                models = []
                status = error.localizedDescription
            }
        }
    }

    private func startTest() {
        busy = true
        probe = nil
        status = "Asking ChatGPT to reply…"
        operation = Task { @MainActor in
            defer { if !Task.isCancelled { busy = false } }
            do {
                let reply = try await CodexCLIService.sendSubscription(
                    message: "Reply with exactly: ready", systemPrompt: "",
                    model: settings.chatGPTSubscriptionModel, timeout: 45)
                try Task.checkCancellation()
                status = "Signed in with ChatGPT · Ready"
                probe = "Answered: \(reply.prefix(60))"
            } catch is CancellationError { return }
            catch { status = error.localizedDescription }
        }
    }
}

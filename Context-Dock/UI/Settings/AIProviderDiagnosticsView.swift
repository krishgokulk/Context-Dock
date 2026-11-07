import SwiftUI

// MARK: - AI Provider Diagnostics
//
// Moved out of the AI Providers page (owner 2026-11-07): choosing a provider and
// testing / pricing it are different jobs, and the test buttons, per-model rate card,
// AppleScript specialist and raw diagnostics panel were crowding the one screen where
// someone picks a model. They live under Advanced now and act on whatever provider the
// AI Providers page is set to.

struct AIProviderDiagnosticsView: View {
    @ObservedObject var settings = AppSettings.shared

    @State private var isTestingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?
    @State private var isRunningProviderQA = false
    @State private var isTestingAppleScriptModel = false
    @State private var appleScriptModelTestMessage: String?
    @State private var appleScriptModelTestOK = false

    /// Typed rather than numeric: an empty field means "not priced", which a Double cannot
    /// express, and a half-typed "3." must not be read as a rate mid-keystroke.
    @State private var rateInput = ""
    @State private var rateOutput = ""
    @State private var rateCached = ""

    enum ConnectionTestResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CardSection(title: "Connection & QA", systemImage: "network") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tests the provider selected in AI Providers: \(settings.selectedAIProvider.displayName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if settings.selectedAIProvider != .onDevice
                        && settings.selectedAIProvider != .shortcuts {
                        HStack(spacing: 10) {
                            Button(action: testConnection) {
                                HStack(spacing: 8) {
                                    if isTestingConnection {
                                        ProgressView().scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "network")
                                    }
                                    Text("Test Connection")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isTestingConnection || !settings.isProviderConfigured(settings.selectedAIProvider))

                            if let result = connectionTestResult {
                                connectionResultView(result)
                            }
                        }

                        HStack {
                            Button("Test Text") { testProviderText() }
                            Button("Test Vision") { testProviderVision() }
                            Button("Test Tool Calls") { testProviderToolCalls() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            isRunningProviderQA
                                || !settings.isProviderConfigured(settings.selectedAIProvider)
                        )
                    } else {
                        Text("On-device and Shortcuts providers do not expose a connection test.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 14)
            }

            CardSection(title: "Cost Per Million Tokens", systemImage: "dollarsign.circle") {
                modelRateCardView
                    .padding(.vertical, 14)
            }

            CardSection(title: "AppleScript Automation Model", systemImage: "applescript") {
                appleScriptAutomationModelView
                    .padding(.vertical, 14)
            }

            DiagnosticsPanel()
        }
    }

    // MARK: - Rate card

    /// What this model costs, entered by the user.
    ///
    /// DoraX counts tokens exactly — the providers report them — but it does not ship a price
    /// table: one is wrong the day a provider changes its pricing page, and someone would
    /// pick a cheaper model on a number the app made up two releases ago. Enter the figures
    /// from the provider's own page and the usage rows show money; leave them empty and they
    /// show tokens and nothing else.
    @ViewBuilder
    private var modelRateCardView: some View {
        let model = currentRateModelID
        VStack(alignment: .leading, spacing: 8) {
            if model.isEmpty {
                Text("Choose a model in AI Providers to record what it costs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    rateField("Input $", value: $rateInput)
                    rateField("Output $", value: $rateOutput)
                    rateField("Cached $", value: $rateCached)
                }
                Text(
                    "From \(settings.selectedAIProvider.displayName)'s pricing page, for "
                    + "\(model). Leave blank to show tokens only. Cached input is billed at "
                    + "the input rate when left empty."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                let spend = AIModelRateCard.shared.todaySpend()
                if spend.amount > 0 {
                    Text(
                        "Today: \(spend.amount.compactUSD)"
                        + (spend.hasUnpriced ? " (plus models with no rate entered)" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { loadRate(for: model) }
        .onChange(of: currentRateModelID) { _, newModel in loadRate(for: newModel) }
    }

    private func rateField(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField("—", text: value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .onSubmit { saveRate() }
        }
    }

    /// The model the rate applies to: whichever one this provider is set to use.
    private var currentRateModelID: String {
        switch settings.selectedAIProvider {
        case .openAI: return settings.selectedOpenAIModel
        case .anthropic: return settings.selectedAnthropicModel
        case .googleGemini: return settings.selectedGeminiModel
        case .ollama: return settings.selectedOllamaModel
        case .openAICompatible: return settings.openAICompatibleModelID
        case .kimi: return settings.selectedKimiModel
        case .claudeBridge: return settings.claudeBridgeModelID
        case .chatGPTBridge: return settings.chatGPTBridgeModelID
        // Claude Code bills nothing per token — the subscription already paid. A rate
        // card for it would invite a number that is not a cost.
        case .onDevice, .shortcuts, .claudeCode, .chatGPTSubscription: return ""
        }
    }

    private func loadRate(for model: String) {
        guard !model.isEmpty, let rate = AIModelRateCard.shared.rate(forModel: model) else {
            rateInput = ""
            rateOutput = ""
            rateCached = ""
            return
        }
        rateInput = String(rate.inputPerMillion)
        rateOutput = String(rate.outputPerMillion)
        rateCached = rate.cachedInputPerMillion.map { String($0) } ?? ""
    }

    private func saveRate() {
        let model = currentRateModelID
        guard !model.isEmpty else { return }
        let input = Double(rateInput.trimmingCharacters(in: .whitespaces))
        let output = Double(rateOutput.trimmingCharacters(in: .whitespaces))
        // Both halves or neither: a rate with only one side priced would report a cost that
        // is wrong in a direction the user cannot see.
        guard let input, let output else {
            AIModelRateCard.shared.set(nil, forModel: model)
            return
        }
        AIModelRateCard.shared.set(
            AIModelRate(
                inputPerMillion: input,
                outputPerMillion: output,
                cachedInputPerMillion: Double(rateCached.trimmingCharacters(in: .whitespaces))),
            forModel: model)
    }

    // MARK: - AppleScript specialist

    // Optional specialist backend: a model fine-tuned for NL→AppleScript (e.g. Osaurus
    // AppleScript-8B/16B). Independent of the chat provider above — used only by the
    // action/execution layer when no deterministic route exists. Chat stays on whatever
    // provider is selected.
    private var appleScriptAutomationModelView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Enable specialist model")
                    .font(.subheadline).fontWeight(.medium)
                Spacer()
                Toggle("", isOn: $settings.appleScriptModelEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Text("Optional specialist that turns automation requests into AppleScript in the action layer — your chat provider is unchanged. Great with Osaurus AppleScript-8B/16B; it does NOT chat, so don't set it as your main model.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.appleScriptModelEnabled {
                Button("Osaurus Preset") {
                    settings.appleScriptModelEndpoint = "http://127.0.0.1:1337/v1"
                    if settings.appleScriptModelID.isEmpty {
                        settings.appleScriptModelID = "AppleScript-8B"
                    }
                }
                .buttonStyle(.bordered)

                Text("Endpoint")
                    .font(.subheadline).fontWeight(.medium)
                TextField("http://127.0.0.1:1337/v1", text: $settings.appleScriptModelEndpoint)
                    .textFieldStyle(.roundedBorder)

                Text("Model ID")
                    .font(.subheadline).fontWeight(.medium)
                TextField("AppleScript-8B", text: $settings.appleScriptModelID)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button(action: testAppleScriptModel) {
                        HStack(spacing: 6) {
                            if isTestingAppleScriptModel {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "network")
                            }
                            Text("Test AppleScript Model")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        isTestingAppleScriptModel
                        || settings.appleScriptModelEndpoint.isEmpty
                        || settings.appleScriptModelID.isEmpty)
                    if let appleScriptModelTestMessage {
                        Label(
                            appleScriptModelTestMessage,
                            systemImage: appleScriptModelTestOK
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(appleScriptModelTestOK ? .green : .red)
                        .lineLimit(2)
                    }
                }
            }
        }
    }

    private func testAppleScriptModel() {
        isTestingAppleScriptModel = true
        appleScriptModelTestMessage = nil
        Task {
            let result = await AppleScriptModelService.shared.testConnection()
            await MainActor.run {
                isTestingAppleScriptModel = false
                switch result {
                case let .success(message):
                    appleScriptModelTestOK = true
                    appleScriptModelTestMessage = message
                case let .failure(error):
                    appleScriptModelTestOK = false
                    appleScriptModelTestMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Connection & QA

    @ViewBuilder
    private func connectionResultView(_ result: ConnectionTestResult) -> some View {
        switch result {
        case .success(let message):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .foregroundStyle(.green)
            }
            .font(.caption)
        case .failure(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
            }
            .font(.caption)
        }
    }

    private func testConnection() {
        isTestingConnection = true
        connectionTestResult = nil

        Task {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000) // Simulate network delay

                switch settings.selectedAIProvider {
                case .ollama:
                    let endpoint = settings.ollamaEndpoint.trimmingCharacters(in: .whitespaces)
                    guard let url = URL(string: "\(endpoint)/api/tags") else {
                        throw NSError(domain: "Invalid URL", code: -1)
                    }

                    let (_, response) = try await URLSession.shared.data(from: url)
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        await MainActor.run {
                            connectionTestResult = .success("Connected to Ollama")
                        }
                    } else {
                        throw NSError(domain: "Connection failed", code: -1)
                    }

                case .openAI, .googleGemini, .anthropic:
                    let key = settings.getAPIKey(for: settings.selectedAIProvider)
                    if key.count > 10 {
                        await MainActor.run {
                            connectionTestResult = .success("API key looks valid")
                        }
                    } else {
                        throw NSError(domain: "API key too short", code: -1)
                    }

                case .openAICompatible:
                    guard settings.isProviderConfigured(.openAICompatible) else {
                        throw NSError(domain: "Endpoint and model are required", code: -1)
                    }
                    let response = try await AIProviderRouter.shared.send(
                        AIRequest(
                            text: "Reply with OK.",
                            context: .none,
                            source: .aiChat,
                            additionalContextPrompt: "Connection test. Return only OK."
                        ),
                        provider: .openAICompatible
                    )
                    guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw NSError(domain: "Compatible endpoint returned an empty response", code: -1)
                    }
                    await MainActor.run {
                        connectionTestResult = .success("OpenAI-compatible endpoint responded")
                    }

                default:
                    break
                }
            } catch {
                await MainActor.run {
                    connectionTestResult = .failure("Connection failed: \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                isTestingConnection = false
            }
        }
    }

    private func testProviderText() {
        runProviderQA {
            let response = try await AIProviderRouter.shared.send(
                AIRequest(text: "Reply with TEXT_OK only.", context: .none, source: .aiChat),
                provider: settings.selectedAIProvider
            )
            guard response.uppercased().contains("TEXT_OK") else {
                throw AIServiceError.emptyResponse("Text test returned unexpected response")
            }
            return "Text test passed"
        }
    }

    private func testProviderVision() {
        runProviderQA {
            guard AIProviderRouter.shared.capabilities(for: settings.selectedAIProvider)
                .supportsImages
            else {
                throw AIServiceError.unsupportedProvider(
                    "The selected provider or model does not support image input")
            }
            guard let data = visionTestImageData() else {
                throw AIServiceError.networkError("Could not create vision test image")
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("context-dock-vision-test.png")
            try data.write(to: url, options: .atomic)
            defer { try? FileManager.default.removeItem(at: url) }
            let response = try await AIProviderRouter.shared.send(
                AIRequest(
                    text: "What is the dominant color of this image? Reply briefly.",
                    context: .none,
                    attachments: [.init(kind: .image, url: url)],
                    source: .aiChat
                ),
                provider: settings.selectedAIProvider
            )
            guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIServiceError.emptyResponse("Vision test returned empty response")
            }
            return "Vision test passed"
        }
    }

    /// A provider-safe fixture. The previous 1×1 PNG was valid but below the practical
    /// minimum accepted by several vision APIs, which made every provider look broken.
    private func visionTestImageData() -> Data? {
        let width = 128
        let height = 128
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let pixels = bitmap.bitmapData else { return nil }

        for index in stride(from: 0, to: width * height * 4, by: 4) {
            pixels[index] = 45
            pixels[index + 1] = 115
            pixels[index + 2] = 230
            pixels[index + 3] = 255
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func testProviderToolCalls() {
        runProviderQA {
            let provider = settings.selectedAIProvider
            guard provider != .onDevice, provider != .shortcuts else {
                throw AIServiceError.unsupportedProvider("Selected provider does not support tool-call QA")
            }
            let key = provider.requiresAPIKey ? settings.getAPIKey(for: provider) : nil
            let result = try await AIProviderService.shared.sendWithTools(
                "Call run_command once with command `echo TOOL_OK` and purpose `Provider tool-call QA`.",
                context: .none,
                provider: provider,
                apiKey: key,
                conversationHistory: [],
                commandExecutor: { command, _, _ in
                    (true, command.contains("TOOL_OK") ? "TOOL_OK" : "Simulated tool output", 0)
                },
                maxIterations: 2,
                systemPromptOverride: "You are running provider QA. Call requested tool exactly once.",
                simulateAllTools: true
            )
            guard !result.executedCommands.isEmpty else {
                throw AIServiceError.emptyResponse("Provider did not produce a tool call")
            }
            return "Tool-call test passed"
        }
    }

    private func runProviderQA(_ operation: @escaping @MainActor () async throws -> String) {
        isRunningProviderQA = true
        connectionTestResult = nil
        Task {
            do {
                let message = try await operation()
                connectionTestResult = .success(message)
            } catch {
                connectionTestResult = .failure("QA failed: \(error.localizedDescription)")
            }
            isRunningProviderQA = false
        }
    }
}

// MARK: - Diagnostics sheet (presented from Advanced)

struct AIProviderDiagnosticsSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("AI Provider Diagnostics", systemImage: "stethoscope")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                AIProviderDiagnosticsView()
                    .padding(20)
            }
        }
        .frame(width: 560, height: 560)
    }
}

// MARK: - Context-Dock MCP Server card (moved to Advanced)

struct DoraXMCPServerCard: View {
    @AppStorage(DoraXMCPServer.enabledKey) private var mcpEnabled = false
    @ObservedObject private var server = DoraXMCPServer.shared

    @State private var copiedCommand = false
    @State private var copiedSnippet = false
    @State private var copiedToken = false

    var body: some View {
        CardSection(title: "Context-Dock MCP Server", systemImage: "antenna.radiowaves.left.and.right") {
            VStack(spacing: 0) {
                SettingsPageRow(
                    icon: "eye.fill",
                    iconColor: .teal,
                    title: "Enable Native MCP Server",
                    subtitle:
                        "Expose Context-Dock's 5 universal tools (look, do, script, read_data, ask) "
                        + "to Claude Code, Claude Desktop, Cursor, Codex, and external AI providers. "
                        + "Local-only on 127.0.0.1, protected by Bearer token authentication."
                ) {
                    Toggle("", isOn: $mcpEnabled)
                        .labelsHidden()
                        .onChange(of: mcpEnabled) { _, on in
                            on ? DoraXMCPServer.shared.start() : DoraXMCPServer.shared.stop()
                        }
                }
                if mcpEnabled {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(server.isRunning ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(server.isRunning ? "Running on http://127.0.0.1:\(DoraXMCPServer.port)/mcp" : "Starting server…")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(server.isRunning ? .primary : .secondary)
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Button {
                                copy(DoraXMCPServer.registrationCommand, flag: $copiedCommand)
                            } label: {
                                Label(copiedCommand ? "Copied Command!" : "Copy CLI Command",
                                      systemImage: copiedCommand ? "checkmark" : "terminal")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!server.isRunning)

                            Button {
                                copy(DoraXMCPServer.jsonConfigurationSnippet, flag: $copiedSnippet)
                            } label: {
                                Label(copiedSnippet ? "Copied JSON!" : "Copy JSON Config",
                                      systemImage: copiedSnippet ? "checkmark" : "curlybraces")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!server.isRunning)

                            Button {
                                copy(DoraXMCPServer.token, flag: $copiedToken)
                            } label: {
                                Label(copiedToken ? "Copied Token!" : "Copy Token",
                                      systemImage: copiedToken ? "checkmark" : "key")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!server.isRunning)
                        }

                        DisclosureGroup("View MCP Config Snippet") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Add to claude_desktop_config.json, Cursor, or your AI client settings:")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                ScrollView(.horizontal) {
                                    Text(DoraXMCPServer.jsonConfigurationSnippet)
                                        .font(.system(size: 10, design: .monospaced))
                                        .padding(8)
                                }
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .padding(.top, 4)
                        }
                        .font(.system(size: 11))
                    }
                    .padding(14)
                }
            }
        }
    }

    private func copy(_ string: String, flag: Binding<Bool>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        flag.wrappedValue = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            flag.wrappedValue = false
        }
    }
}

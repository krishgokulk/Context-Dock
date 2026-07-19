import AppKit
import Foundation

enum AIRequestMode: String, Codable {
    case answer
    case plan
    case execute
    case explainResult
}

enum AIRequestSource: String, Codable {
    case globalContext
    case contextDock
    case mediaDock
    case aiChat
    case extensionSystem
    case workflow
}

enum AIAttachmentKind: String, Codable {
    case image
    case file
    case pdf
    case url
}

struct AIAttachment: Identifiable, Codable {
    let id: UUID
    let kind: AIAttachmentKind
    let url: URL

    init(kind: AIAttachmentKind, url: URL, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.url = url
    }

    static func inferred(from url: URL) -> AIAttachment {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) {
            return AIAttachment(kind: .image, url: url)
        }
        if ext == "pdf" {
            return AIAttachment(kind: .pdf, url: url)
        }
        return AIAttachment(kind: url.isFileURL ? .file : .url, url: url)
    }
}

struct AIRequest {
    var text: String
    var context: UserContext
    var history: [ChatMessage] = []
    var attachments: [AIAttachment] = []
    var mode: AIRequestMode = .answer
    var source: AIRequestSource = .aiChat
    var liveContext: AIContextSnapshot? = nil
    var includesWorkflowCapabilities = false
    var additionalContextPrompt = ""
    var providerSelection: AIProviderSelection? = nil
}

typealias AIContextSnapshot = ContextSnapshot

struct AIProviderCapabilities {
    let supportsImages: Bool
    let supportsFiles: Bool
    let supportsToolCalls: Bool
    let runsLocally: Bool
}

struct AIProviderAdapterConfiguration {
    let apiKey: String
    let endpoint: String
    let modelID: String
}

protocol AIProviderAdapter {
    var provider: AIProvider { get }
    var capabilities: AIProviderCapabilities { get }

    func send(
        request: AIRequest,
        contextPrompt: String,
        configuration: AIProviderAdapterConfiguration
    ) async throws -> String
}

private enum AIProviderHTTP {
    static func request(
        url: URL,
        headers: [String: String] = [:],
        body: [String: Any],
        timeout: TimeInterval = 60
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await AIProviderService.directSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.networkError("Invalid provider response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AIServiceError.authenticationFailed("Provider authentication failed")
            }
            throw AIServiceError.networkError("Provider HTTP \(http.statusCode): \(detail)")
        }
        return data
    }

    static func chatMessages(
        message: String,
        contextPrompt: String,
        history: [ChatMessage]
    ) -> [[String: String]] {
        var messages = [["role": "system", "content": contextPrompt]]
        messages += history.suffix(10)
            .filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }
        messages.append(["role": "user", "content": message])
        return messages
    }

    static func imageData(for attachments: [AIAttachment]) -> [(data: String, mediaType: String)] {
        // Normalizes any image format (heic/tiff/bmp/…) to a provider-safe MIME type;
        // sending those raw types used to 400 silently on Anthropic/OpenAI vision.
        AIAttachmentPreparer.imageBlocks(for: attachments)
    }
}

struct OpenAIProviderAdapter: AIProviderAdapter {
    let provider: AIProvider = .openAI
    let capabilities = AIProviderCapabilities(
        supportsImages: true, supportsFiles: false, supportsToolCalls: true, runsLocally: false
    )

    func send(
        request: AIRequest,
        contextPrompt: String,
        configuration: AIProviderAdapterConfiguration
    ) async throws -> String {
        try await OpenAICompatibleProviderAdapter.sendCompatible(
            request: request,
            contextPrompt: contextPrompt,
            configuration: configuration
        )
    }
}

struct OpenAICompatibleProviderAdapter: AIProviderAdapter {
    let provider: AIProvider = .openAICompatible
    let capabilities = AIProviderCapabilities(
        supportsImages: true, supportsFiles: false, supportsToolCalls: true, runsLocally: false
    )

    func send(
        request: AIRequest,
        contextPrompt: String,
        configuration: AIProviderAdapterConfiguration
    ) async throws -> String {
        try await Self.sendCompatible(
            request: request,
            contextPrompt: contextPrompt,
            configuration: configuration
        )
    }

    static func sendCompatible(
        request: AIRequest,
        contextPrompt: String,
        configuration: AIProviderAdapterConfiguration
    ) async throws -> String {
        guard let url = completionURL(from: configuration.endpoint) else {
            throw AIServiceError.networkError("Invalid OpenAI-compatible endpoint")
        }
        var headers: [String: String] = [:]
        if !configuration.apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(configuration.apiKey)"
        }
        var messages: [[String: Any]] = [["role": "system", "content": contextPrompt]]
        messages += request.history.suffix(10)
            .filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }
        let images = AIProviderHTTP.imageData(for: request.attachments)
        if images.isEmpty {
            messages.append(["role": "user", "content": request.text])
        } else {
            var content: [[String: Any]] = [["type": "text", "text": request.text]]
            content += images.map {
                [
                    "type": "image_url",
                    "image_url": ["url": "data:\($0.mediaType);base64,\($0.data)"],
                ]
            }
            messages.append(["role": "user", "content": content])
        }
        let data = try await AIProviderHTTP.request(
            url: url,
            headers: headers,
            body: [
                "model": configuration.modelID,
                "messages": messages,
                // No temperature: newer Claude models served through OpenAI-compatible
                // proxies reject sampling parameters with HTTP 400.
                "max_tokens": 1000,
            ]
        )
        let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = response.choices.first?.message.content, !content.isEmpty else {
            throw AIServiceError.emptyResponse("No response from OpenAI-compatible provider")
        }
        return content
    }

    private static func completionURL(from endpoint: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("chat/completions") {
            return URL(string: trimmed)
        }
        return URL(string: "\(trimmed)/chat/completions")
    }

    private struct OpenAIResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String }
    }
}

struct AnthropicProviderAdapter: AIProviderAdapter {
    let provider: AIProvider = .anthropic
    let capabilities = AIProviderCapabilities(
        supportsImages: true, supportsFiles: false, supportsToolCalls: true, runsLocally: false
    )

    func send(
        request: AIRequest,
        contextPrompt: String,
        configuration: AIProviderAdapterConfiguration
    ) async throws -> String {
        var messages: [[String: Any]] = request.history.suffix(10)
            .filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }
        let images = AIProviderHTTP.imageData(for: request.attachments)
        if images.isEmpty {
            messages.append(["role": "user", "content": request.text])
        } else {
            var content: [[String: Any]] = images.map {
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": $0.mediaType,
                        "data": $0.data,
                    ],
                ]
            }
            content.append(["type": "text", "text": request.text])
            messages.append(["role": "user", "content": content])
        }
        guard let url = URL(string: configuration.endpoint) else {
            throw AIServiceError.networkError("Invalid Anthropic endpoint")
        }
        let data = try await AIProviderHTTP.request(
            url: url,
            headers: [
                "x-api-key": configuration.apiKey,
                "anthropic-version": "2023-06-01",
            ],
            body: [
                "model": configuration.modelID,
                "system": contextPrompt,
                "messages": messages,
                "max_tokens": 1024,
            ]
        )
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let content = response.content.first?.text, !content.isEmpty else {
            throw AIServiceError.emptyResponse("No response from Anthropic")
        }
        return content
    }

    private struct Response: Decodable {
        let content: [Content]
        struct Content: Decodable { let text: String }
    }
}

struct GeminiProviderAdapter: AIProviderAdapter {
    let provider: AIProvider = .googleGemini
    let capabilities = AIProviderCapabilities(
        supportsImages: true, supportsFiles: false, supportsToolCalls: true, runsLocally: false
    )

    func send(
        request: AIRequest,
        contextPrompt: String,
        configuration: AIProviderAdapterConfiguration
    ) async throws -> String {
        var contents: [[String: Any]] = [
            ["role": "user", "parts": [["text": contextPrompt]]],
            ["role": "model", "parts": [["text": "Understood."]]],
        ]
        for item in request.history.suffix(10).filter({ $0.role != .system }) {
            contents.append([
                "role": item.role == .assistant ? "model" : "user",
                "parts": [["text": item.content]],
            ])
        }
        var finalParts: [[String: Any]] = AIProviderHTTP.imageData(for: request.attachments).map {
            ["inlineData": ["mimeType": $0.mediaType, "data": $0.data]]
        }
        finalParts.append(["text": request.text])
        contents.append(["role": "user", "parts": finalParts])
        guard let url = URL(string: configuration.endpoint) else {
            throw AIServiceError.networkError("Invalid Gemini endpoint")
        }
        let data = try await AIProviderHTTP.request(
            url: url,
            headers: ["x-goog-api-key": configuration.apiKey],
            body: [
                "contents": contents,
                "generationConfig": ["temperature": 0.7, "maxOutputTokens": 1000],
            ]
        )
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let content = response.candidates.first?.content.parts.first?.text, !content.isEmpty else {
            throw AIServiceError.emptyResponse("No response from Gemini")
        }
        return content
    }

    private struct Response: Decodable {
        let candidates: [Candidate]
        struct Candidate: Decodable { let content: Content }
        struct Content: Decodable { let parts: [Part] }
        struct Part: Decodable { let text: String }
    }
}

struct OllamaProviderAdapter: AIProviderAdapter {
    let provider: AIProvider = .ollama
    let capabilities = AIProviderCapabilities(
        supportsImages: true, supportsFiles: false, supportsToolCalls: true, runsLocally: true
    )

    func send(
        request: AIRequest,
        contextPrompt: String,
        configuration: AIProviderAdapterConfiguration
    ) async throws -> String {
        let endpoint = configuration.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(endpoint)/api/chat") else {
            throw AIServiceError.networkError("Invalid Ollama endpoint")
        }
        var messages: [[String: Any]] = [["role": "system", "content": contextPrompt]]
        messages += request.history.suffix(10)
            .filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }
        var userMessage: [String: Any] = ["role": "user", "content": request.text]
        let images = AIProviderHTTP.imageData(for: request.attachments).map(\.data)
        if !images.isEmpty { userMessage["images"] = images }
        messages.append(userMessage)
        let data = try await AIProviderHTTP.request(
            url: url,
            body: [
                "model": configuration.modelID,
                "messages": messages,
                "stream": false,
                "options": ["temperature": 0.7, "num_predict": 1000],
            ],
            timeout: 120
        )
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.message.content
    }

    private struct Response: Decodable {
        let message: Message
        struct Message: Decodable { let content: String }
    }
}

struct ShortcutsProviderAdapter: AIProviderAdapter {
    let provider: AIProvider = .shortcuts
    let capabilities = AIProviderCapabilities(
        supportsImages: false, supportsFiles: false, supportsToolCalls: false, runsLocally: true
    )

    func send(
        request: AIRequest,
        contextPrompt: String,
        configuration: AIProviderAdapterConfiguration
    ) async throws -> String {
        let shortcutName = configuration.modelID
        guard !shortcutName.isEmpty else {
            throw AIServiceError.unsupportedProvider("Configure a Shortcut in AI Settings first.")
        }
        let input = "\(contextPrompt)\n\nUser request: \(request.text)"
        let escapedName = escape(shortcutName)
        let escapedInput = escape(input)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let source = """
                    tell application "Shortcuts"
                        set shortcutResult to run shortcut "\(escapedName)" with input "\(escapedInput)"
                        return shortcutResult as text
                    end tell
                    """
                var details: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: AIServiceError.networkError("Could not create Shortcuts request"))
                    return
                }
                let output = script.executeAndReturnError(&details)
                if let details {
                    let message = details["NSAppleScriptErrorMessage"] as? String ?? "Shortcuts execution failed"
                    continuation.resume(throwing: AIServiceError.networkError(message))
                    return
                }
                continuation.resume(returning: output.stringValue ?? "")
            }
        }
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

@MainActor
final class AIProviderRouter {
    static let shared = AIProviderRouter()

    private let settings: AppSettings
    private let contextBuilder: AIContextBuilder
    private let safetyPolicy: AISafetyPolicy

    init(
        settings: AppSettings? = nil,
        contextBuilder: AIContextBuilder? = nil,
        safetyPolicy: AISafetyPolicy? = nil
    ) {
        self.settings = settings ?? .shared
        self.contextBuilder = contextBuilder ?? .shared
        self.safetyPolicy = safetyPolicy ?? .shared
    }

    func send(_ request: AIRequest, provider providerOverride: AIProvider? = nil) async throws -> String {
        let profile = AIProfileStore.shared.profile(for: request)
        // The provider visible in the UI is authoritative. Profiles decorate prompts and
        // constrain tools, but must not silently replace the user's selected model.
        let selection = providerOverride.map(AIProviderSelection.explicit)
            ?? request.providerSelection
            ?? AIProviderSelectionResolver.current(settings: settings)
        let provider = selection.effectiveProvider
        var contextPrompt = contextBuilder.build(request: request)
        contextPrompt = AIProfileRouter.decoratedContextPrompt(contextPrompt, profile: profile, request: request)
        return try await sendPrepared(
            request: request,
            provider: provider,
            contextPrompt: contextPrompt
        )
    }

    func sendPrepared(request: AIRequest, provider: AIProvider, contextPrompt: String) async throws -> String {
        if !safetyPolicy.isLocal(provider),
            request.liveContext?.selectedTextCharacterCount ?? 0 > 0,
            !settings.allowSelectedTextCloudSharing
        {
            throw AIServiceError.unsupportedProvider(
                "Selected text cloud sharing is disabled in AI settings."
            )
        }
        if !safetyPolicy.isLocal(provider),
           request.liveContext?.browserCleanMarkdown?.isEmpty == false,
           !settings.allowSelectedTextCloudSharing
        {
            throw AIServiceError.unsupportedProvider(
                "Web page context cloud sharing is disabled in AI settings."
            )
        }
        if !safetyPolicy.isLocal(provider),
           request.liveContext?.connectedBrowserContexts.contains(where: {
            $0.cleanMarkdown?.isEmpty == false
           }) == true,
           !settings.allowSelectedTextCloudSharing
        {
            throw AIServiceError.unsupportedProvider(
                "Connected browser context cloud sharing is disabled in AI settings."
            )
        }
        try safetyPolicy.validate(message: request.text, context: request.context, provider: provider)
        let assessment = safetyPolicy.assess(
            message: request.text,
            context: request.context,
            provider: provider
        )
        if assessment.containsPrivateCloudData {
            let approved = await AIPrivacyApprovalCenter.shared.request(
                provider: provider,
                context: request.context
            )
            guard approved else {
                throw AIServiceError.unsupportedProvider("Cloud AI request cancelled")
            }
        }

        #if DEBUG
        print("🤖 [AIProviderRouter] source=\(request.source.rawValue) mode=\(request.mode.rawValue) provider=\(provider.rawValue) attachments=\(request.attachments.count)")
        #endif

        let liveContextPrompt =
            request.liveContext == nil || contextPrompt.contains("Shared context snapshot:")
            ? ""
            : "\n\n" + contextBuilder.build(request: request)
        // Extract text from PDFs/documents and fold it into the prompt so every
        // provider can read files even though none accept raw file uploads.
        let attachmentPrompt = attachmentPromptAddendum(
            attachments: request.attachments,
            capabilities: capabilities(for: provider)
        )
        if provider == .onDevice {
            let imageURLs = request.attachments
                .filter { $0.kind == .image }
                .map(\.url)
            return try await AIProviderService.shared.sendPreparedOnDevice(
                message: request.text,
                contextPrompt: contextPrompt + liveContextPrompt + attachmentPrompt,
                history: request.history,
                imageURLs: imageURLs
            )
        }

        let configuration = try configuration(for: provider, apiKeyOverride: nil)
        return try await adapter(for: provider).send(
            request: request,
            contextPrompt: contextPrompt + liveContextPrompt + attachmentPrompt,
            configuration: configuration
        )
    }

    func sendPrepared(
        provider: AIProvider,
        message: String,
        context: UserContext,
        contextPrompt: String,
        apiKeyOverride: String? = nil,
        conversationHistory: [ChatMessage] = [],
        attachments: [AIAttachment] = []
    ) async throws -> String {
        let request = AIRequest(
            text: message,
            context: context,
            history: conversationHistory,
            attachments: attachments,
            source: .aiChat
        )
        try safetyPolicy.validate(message: message, context: context, provider: provider)
        let assessment = safetyPolicy.assess(message: message, context: context, provider: provider)
        if assessment.containsPrivateCloudData {
            let approved = await AIPrivacyApprovalCenter.shared.request(
                provider: provider,
                context: context
            )
            guard approved else {
                throw AIServiceError.unsupportedProvider("Cloud AI request cancelled")
            }
        }
        #if DEBUG
        print("🤖 [AIProviderRouter] legacy-facade provider=\(provider.rawValue) attachments=\(attachments.count)")
        #endif
        let attachmentPrompt = attachmentPromptAddendum(
            attachments: attachments,
            capabilities: capabilities(for: provider)
        )
        if provider == .onDevice {
            let imageURLs = attachments.filter { $0.kind == .image }.map(\.url)
            return try await AIProviderService.shared.sendPreparedOnDevice(
                message: message, contextPrompt: contextPrompt + attachmentPrompt,
                history: conversationHistory, imageURLs: imageURLs
            )
        }
        let configuration = try configuration(for: provider, apiKeyOverride: apiKeyOverride)
        return try await adapter(for: provider).send(
            request: request, contextPrompt: contextPrompt + attachmentPrompt,
            configuration: configuration
        )
    }

    /// Public capability lookup so UI can show vision/file support and gate attachments.
    /// On-device is treated as image-capable because it OCRs images into text.
    func capabilities(for provider: AIProvider) -> AIProviderCapabilities {
        if provider == .onDevice {
            return AIProviderCapabilities(
                supportsImages: true, supportsFiles: false,
                supportsToolCalls: false, runsLocally: true
            )
        }
        return adapter(for: provider).capabilities
    }

    private func configuration(
        for provider: AIProvider,
        apiKeyOverride: String?
    ) throws -> AIProviderAdapterConfiguration {
        let key = apiKeyOverride ?? settings.getAPIKey(for: provider)
        if provider.requiresAPIKey && key.isEmpty {
            throw AIServiceError.missingAPIKey("\(provider.displayName) API key is required")
        }
        switch provider {
        case .openAI:
            return .init(
                apiKey: key,
                endpoint: "https://api.openai.com/v1/chat/completions",
                modelID: settings.selectedOpenAIModel.isEmpty
                    ? "gpt-4o-mini" : settings.selectedOpenAIModel)
        case .anthropic:
            return .init(
                apiKey: key,
                endpoint: "https://api.anthropic.com/v1/messages",
                modelID: settings.selectedAnthropicModel.isEmpty
                    ? AnthropicModelCatalog.defaultModelID : settings.selectedAnthropicModel)
        case .googleGemini:
            return .init(apiKey: key, endpoint: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent", modelID: "gemini-2.0-flash")
        case .ollama:
            return .init(
                apiKey: "",
                endpoint: settings.ollamaEndpoint,
                modelID: settings.selectedOllamaModel.isEmpty ? "llama2" : settings.selectedOllamaModel
            )
        case .openAICompatible:
            guard !settings.openAICompatibleEndpoint.isEmpty, !settings.openAICompatibleModelID.isEmpty else {
                throw AIServiceError.networkError("OpenAI-compatible endpoint and model ID are required")
            }
            return .init(
                apiKey: key,
                endpoint: settings.openAICompatibleEndpoint,
                modelID: settings.openAICompatibleModelID
            )
        case .claudeBridge:
            guard !settings.claudeBridgeEndpoint.isEmpty else {
                throw AIServiceError.networkError("Claude bridge endpoint is required. Start VibeProxy or a compatible bridge.")
            }
            return .init(apiKey: "", endpoint: settings.claudeBridgeEndpoint, modelID: settings.claudeBridgeModelID)
        case .chatGPTBridge:
            guard !settings.chatGPTBridgeEndpoint.isEmpty else {
                throw AIServiceError.networkError("ChatGPT bridge endpoint is required. Start VibeProxy or a compatible bridge.")
            }
            return .init(apiKey: "", endpoint: settings.chatGPTBridgeEndpoint, modelID: settings.chatGPTBridgeModelID)
        case .shortcuts:
            return .init(apiKey: "", endpoint: "", modelID: settings.shortcutsProviderShortcut)
        case .onDevice:
            throw AIServiceError.unsupportedProvider("Provider does not use an HTTP adapter")
        }
    }

    private func adapter(for provider: AIProvider) -> any AIProviderAdapter {
        switch provider {
        case .openAI: return OpenAIProviderAdapter()
        case .anthropic: return AnthropicProviderAdapter()
        case .googleGemini: return GeminiProviderAdapter()
        case .ollama: return OllamaProviderAdapter()
        case .openAICompatible: return OpenAICompatibleProviderAdapter()
        case .claudeBridge, .chatGPTBridge: return OpenAICompatibleProviderAdapter()
        case .shortcuts: return ShortcutsProviderAdapter()
        case .onDevice:
            assertionFailure("Provider does not use an adapter")
            return OpenAICompatibleProviderAdapter()
        }
    }

    /// Folds attachments into the prompt: extracted text for PDFs/documents (so files
    /// are readable even when `supportsFiles` is false), plus a path-only note for
    /// images a non-vision provider can't see and files we genuinely couldn't parse.
    private func attachmentPromptAddendum(
        attachments: [AIAttachment],
        capabilities: AIProviderCapabilities
    ) -> String {
        var addendum = AIAttachmentPreparer.extractedText(for: attachments)

        var unreadable: [AIAttachment] = []
        if !capabilities.supportsImages {
            unreadable += attachments.filter { $0.kind == .image }
        }
        unreadable += AIAttachmentPreparer.unreadableFileAttachments(attachments)

        if !unreadable.isEmpty {
            let paths = unreadable.map { "- \($0.url.path)" }.joined(separator: "\n")
            addendum +=
                "\n\nAttachment note: these could not be read directly; use metadata/path only:\n\(paths)"
        }
        return addendum
    }

    /// Model-aware vision check. The provider-level `supportsImages` flag is optimistic
    /// (it green-lit text-only Ollama / custom models, which then 400 on an image), so
    /// for local and OpenAI-compatible providers we inspect the selected model id.
    func selectedModelSupportsVision(for provider: AIProvider) -> Bool {
        switch provider {
        case .ollama:
            return AIAttachmentPreparer.modelSupportsVision(modelID: settings.selectedOllamaModel)
        case .openAICompatible:
            return AIAttachmentPreparer.modelSupportsVision(
                modelID: settings.openAICompatibleModelID)
        case .shortcuts:
            return false
        default:
            // First-party providers (OpenAI/Anthropic/Gemini) use pinned vision-capable
            // models; on-device OCRs images to text. Trust the provider flag.
            return capabilities(for: provider).supportsImages
        }
    }
}

@MainActor
final class AIActionPlanner {
    static let shared = AIActionPlanner()

    private init() {}

    func capabilityPlanningPrompt(bundleID: String?) -> String {
        """
        Return one JSON action plan only:
        {"capability":"registered.id","input":{"field":"value"},"explanation":"short reason"}

        Use only registered capability IDs. Never invent capabilities or commands.
        If no capability matches, return:
        {"capability":"","input":{},"explanation":"No registered capability matches"}

        \(CapabilityRegistry.shared.promptBlock(for: bundleID))
        """
    }

    func prompt(for manifest: ExtensionManifest, context: ExtensionContext) -> String {
        var lines = ["Extension: \(manifest.name)", "Task: \(manifest.summary)"]
        if !context.selectedText.isEmpty { lines.append("Selected text:\n\(context.selectedText)") }
        if !context.selectedFiles.isEmpty {
            lines.append("Selected files:\n\(context.selectedFiles.map(\.path).joined(separator: "\n"))")
        }
        if let url = context.selectedURL { lines.append("URL: \(url)") }
        return lines.joined(separator: "\n\n")
    }
}

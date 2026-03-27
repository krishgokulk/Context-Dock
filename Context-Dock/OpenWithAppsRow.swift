//
//  OpenWithAppsRow.swift
//  ILauncher
//
//  Shows "Open With" style app suggestions in a horizontal row
//  Similar to PinnedAppsRow but for context-based app suggestions
//

import SwiftUI
import AppKit

// Use the same typealias as AIModeView
typealias OpenWithUserContext = UserContext

struct OpenWithAppsRow: View {
    let fileURLs: [URL]
    let onOpenWith: (DefaultAppResolver.DefaultApp) -> Void

    @State private var openWithSuggestions: [DefaultAppResolver.OpenWithSuggestion] = []
    @State private var hoveredAppId: UUID?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "arrow.up.doc.on.clipboard")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text("Open With")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let firstURL = fileURLs.first {
                    Text("(\(firstURL.pathExtension.uppercased()))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if openWithSuggestions.count > 5 {
                    Text("\(openWithSuggestions.count) apps")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            // Apps row
            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Finding apps...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 60)
            } else if openWithSuggestions.isEmpty {
                HStack {
                    Image(systemName: "questionmark.app")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("No apps found for this file type")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 60)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(openWithSuggestions) { suggestion in
                            OpenWithAppIcon(
                                suggestion: suggestion,
                                isHovered: hoveredAppId == suggestion.id,
                                onTap: {
                                    onOpenWith(suggestion.app)
                                }
                            )
                            .onHover { hovering in
                                hoveredAppId = hovering ? suggestion.id : nil
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 70)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
        .onAppear {
            loadSuggestions()
        }
        .onChange(of: fileURLs) { _ in
            loadSuggestions()
        }
    }

    private func loadSuggestions() {
        isLoading = true

        DispatchQueue.global(qos: .userInteractive).async {
            let suggestions = DefaultAppResolver.shared.getOpenWithSuggestions(for: fileURLs)

            DispatchQueue.main.async {
                openWithSuggestions = suggestions
                isLoading = false
            }
        }
    }
}

struct OpenWithAppIcon: View {
    let suggestion: DefaultAppResolver.OpenWithSuggestion
    let isHovered: Bool
    let onTap: () -> Void

    private var appIcon: NSImage {
        let icon = NSWorkspace.shared.icon(forFile: suggestion.app.path.path)
        icon.size = NSSize(width: 48, height: 48)
        return icon
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    // App icon
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                        .scaleEffect(isHovered ? 1.1 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)

                    // Default badge
                    if suggestion.isDefault {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white, .green)
                            .offset(x: 4, y: 4)
                    }
                }

                // App name
                Text(suggestion.app.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 60)
            }
        }
        .buttonStyle(.plain)
        .help(suggestion.isDefault ? "\(suggestion.app.displayName) (default)" : suggestion.app.displayName)
    }
}

// MARK: - Compact version for L2 input area

struct OpenWithCompactRow: View {
    let fileURLs: [URL]
    let onOpenWith: (DefaultAppResolver.DefaultApp) -> Void

    @State private var suggestions: [DefaultAppResolver.OpenWithSuggestion] = []
    @State private var isLoaded = false

    var body: some View {
        Group {
            if isLoaded && !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions.prefix(6)) { suggestion in
                            Button(action: {
                                onOpenWith(suggestion.app)
                            }) {
                                HStack(spacing: 4) {
                                    // Mini app icon
                                    Image(nsImage: getAppIcon(for: suggestion.app))
                                        .resizable()
                                        .frame(width: 16, height: 16)

                                    Text(suggestion.app.displayName)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)

                                    if suggestion.isDefault {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.green)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(suggestion.isDefault ? Color.blue.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(suggestion.isDefault ? Color.blue.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .help(suggestion.action)
                        }

                        // Show "more" if there are more apps
                        if suggestions.count > 6 {
                            Text("+\(suggestions.count - 6) more")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                        }
                    }
                }
            }
        }
        .onAppear {
            loadSuggestions()
        }
        .onChange(of: fileURLs) { _ in
            loadSuggestions()
        }
    }

    private func loadSuggestions() {
        DispatchQueue.global(qos: .userInteractive).async {
            let results = DefaultAppResolver.shared.getOpenWithSuggestions(for: fileURLs)

            DispatchQueue.main.async {
                suggestions = results
                isLoaded = true
            }
        }
    }

    private func getAppIcon(for app: DefaultAppResolver.DefaultApp) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: app.path.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

// MARK: - Context App Suggestions Row (Pinned Apps Style)
// Shows app and extension suggestions in a horizontal row like pinned apps

struct ContextAppSuggestionsRow: View {
    let context: OpenWithUserContext
    let onOpenWith: (DefaultAppResolver.DefaultApp) -> Void
    let onRunExtension: (ScriptExtension) -> Void

    @State private var appSuggestions: [DefaultAppResolver.OpenWithSuggestion] = []
    @State private var extensionSuggestions: [SuggestedExtension] = []
    @State private var hoveredItemId: String?
    @State private var isLoaded = false
    @State private var lastContextId: String = ""

    // Unique identifier for context to detect changes
    private var contextId: String {
        switch context {
        case .filesSelected(let urls):
            return "files-\(urls.map { $0.path }.joined(separator: ","))"
        case .textSelected(let text):
            return "text-\(text.hashValue)"
        case .appFocused(let name, let bundleId):
            return "app-\(bundleId)-\(name)"
        case .url(let url):
            return "url-\(url)"
        case .contactSelected(let contact):
            return "contact-\(contact)"
        case .none:
            return "none"
        }
    }

    var body: some View {
        Group {
            if isLoaded && (!appSuggestions.isEmpty || !extensionSuggestions.isEmpty) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // App suggestions (for files) - these should be "Open With" apps
                        ForEach(appSuggestions.prefix(6)) { suggestion in
                            AppSuggestionIcon(
                                suggestion: suggestion,
                                isHovered: hoveredItemId == "app-\(suggestion.id)",
                                onTap: {
                                    onOpenWith(suggestion.app)
                                }
                            )
                            .onHover { hovering in
                                hoveredItemId = hovering ? "app-\(suggestion.id)" : nil
                            }
                        }

                        // Divider if both exist
                        if !appSuggestions.isEmpty && !extensionSuggestions.isEmpty {
                            Divider()
                                .frame(height: 40)
                        }

                        // Extension suggestions (for all contexts)
                        ForEach(extensionSuggestions.prefix(4)) { suggestion in
                            ExtensionSuggestionIcon(
                                suggestion: suggestion,
                                isHovered: hoveredItemId == "ext-\(suggestion.id)",
                                onTap: {
                                    onRunExtension(suggestion.scriptExtension)
                                }
                            )
                            .onHover { hovering in
                                hoveredItemId = hovering ? "ext-\(suggestion.id)" : nil
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
                .frame(height: 60)
            }
        }
        .onAppear {
            print("🎨 [ContextAppSuggestionsRow] onAppear - context: \(context.description)")
            loadSuggestions()
        }
        .onChange(of: contextId) { newValue in
            print("🎨 [ContextAppSuggestionsRow] Context changed to: \(newValue)")
            // Reset and reload when context changes
            isLoaded = false
            appSuggestions = []
            extensionSuggestions = []
            loadSuggestions()
        }
        .id(contextId) // Force view recreation when context changes
    }

    private func loadSuggestions() {
        print("🔄 [ContextAppSuggestionsRow] Loading suggestions for context: \(context.description)")

        DispatchQueue.global(qos: .userInteractive).async {
            var apps: [DefaultAppResolver.OpenWithSuggestion] = []
            var extensions: [SuggestedExtension] = []

            switch context {
            case .filesSelected(let urls):
                print("📁 [ContextAppSuggestionsRow] Files selected: \(urls.map { $0.lastPathComponent })")

                // Get "Open With" app suggestions for files
                apps = DefaultAppResolver.shared.getOpenWithSuggestions(for: urls)
                print("📱 [ContextAppSuggestionsRow] Found \(apps.count) apps that can open these files")
                for app in apps.prefix(5) {
                    print("   - \(app.app.displayName) \(app.isDefault ? "(default)" : "")")
                }

                // Get relevant extensions (but not app-based ones since we show apps separately)
                let detectedContext = DetectedContext.files(urls)
                extensions = IntelligentExtensionMatcher.shared.suggestExtensions(for: detectedContext)
                    .filter { $0.scriptExtension.targetApp == nil } // Only show non-app extensions
                    .filter { !$0.scriptExtension.name.contains("open-with") }
                print("🔧 [ContextAppSuggestionsRow] Found \(extensions.count) extensions for files")

            case .textSelected(let text):
                print("📝 [ContextAppSuggestionsRow] Text selected: \(text.prefix(50))...")
                let detectedContext = DetectedContext.text(text)
                extensions = IntelligentExtensionMatcher.shared.suggestExtensions(for: detectedContext)

            case .appFocused(let name, let bundleId):
                print("🖥️ [ContextAppSuggestionsRow] App focused: \(name)")
                let detectedContext = DetectedContext.app(bundleID: bundleId, name: name)
                extensions = IntelligentExtensionMatcher.shared.suggestExtensions(for: detectedContext)

            case .url(let url):
                print("🔗 [ContextAppSuggestionsRow] URL context: \(url)")
                let detectedContext = DetectedContext.text(url)
                extensions = IntelligentExtensionMatcher.shared.suggestExtensions(for: detectedContext)

            case .contactSelected(let contact):
                print("👤 [ContextAppSuggestionsRow] Contact selected: \(contact)")
                let detectedContext = DetectedContext.text(contact)
                extensions = IntelligentExtensionMatcher.shared.suggestExtensions(for: detectedContext)

            case .none:
                print("⚪ [ContextAppSuggestionsRow] No context - checking clipboard")
                if let clipboardText = NSPasteboard.general.string(forType: .string), !clipboardText.isEmpty {
                    let detectedContext = DetectedContext.text(clipboardText)
                    extensions = IntelligentExtensionMatcher.shared.suggestExtensions(for: detectedContext)
                }
            }

            DispatchQueue.main.async {
                print("✅ [ContextAppSuggestionsRow] Loaded \(apps.count) apps, \(extensions.count) extensions")
                appSuggestions = apps
                extensionSuggestions = extensions
                isLoaded = true
            }
        }
    }
}

// MARK: - App Suggestion Icon (Pinned Apps Style)

struct AppSuggestionIcon: View {
    let suggestion: DefaultAppResolver.OpenWithSuggestion
    let isHovered: Bool
    let onTap: () -> Void

    private var appIcon: NSImage {
        let icon = NSWorkspace.shared.icon(forFile: suggestion.app.path.path)
        icon.size = NSSize(width: 40, height: 40)
        return icon
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                        .scaleEffect(isHovered ? 1.15 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)

                    if suggestion.isDefault {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white, .green)
                            .offset(x: 3, y: 3)
                    }
                }

                Text(suggestion.app.displayName)
                    .font(.system(size: 9))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 50)
            }
        }
        .buttonStyle(.plain)
        .help(suggestion.isDefault ? "\(suggestion.app.displayName) (default)" : suggestion.app.displayName)
    }
}

// MARK: - Extension Suggestion Icon (Pinned Apps Style)

struct ExtensionSuggestionIcon: View {
    let suggestion: SuggestedExtension
    let isHovered: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(iconBackgroundColor.opacity(0.2))
                        .frame(width: 40, height: 40)

                    Image(systemName: suggestion.scriptExtension.type.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(iconColor)
                }
                .scaleEffect(isHovered ? 1.15 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)

                Text(suggestion.scriptExtension.displayName)
                    .font(.system(size: 9))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 50)
            }
        }
        .buttonStyle(.plain)
        .help(suggestion.reason)
    }

    private var iconColor: Color {
        switch suggestion.relevanceScore {
        case 90...: return .green
        case 70..<90: return .blue
        default: return .orange
        }
    }

    private var iconBackgroundColor: Color {
        iconColor
    }
}

// MARK: - Preview

#Preview {
    VStack {
        OpenWithAppsRow(
            fileURLs: [URL(fileURLWithPath: "/Users/test/document.pdf")],
            onOpenWith: { app in
                print("Open with: \(app.displayName)")
            }
        )

        OpenWithCompactRow(
            fileURLs: [URL(fileURLWithPath: "/Users/test/archive.zip")],
            onOpenWith: { app in
                print("Open with: \(app.displayName)")
            }
        )
    }
    .frame(width: 500)
    .padding()
}

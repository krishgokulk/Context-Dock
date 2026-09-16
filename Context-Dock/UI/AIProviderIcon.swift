// AIProviderIcon.swift
// Context-Dock
//
// The provider's own mark, wherever a provider is shown.
//
// SF Symbols has no OpenAI or Anthropic logo, so providers were drawn as approximations —
// ChatGPT as two speech bubbles, Claude as a head silhouette. A user who has ChatGPT on
// their Mac reads the real mark instantly and the stand-in not at all.
//
// The vendor's own app already carries its icon, so when it is installed that is what gets
// drawn. Nothing is shipped, nothing is scraped, and the symbol remains the fallback for
// providers with no app of their own.

import AppKit
import SwiftUI

struct AIProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 14

    var body: some View {
        if let icon = Self.appIcon(for: provider) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size + 2, height: size + 2)
                .clipShape(RoundedRectangle(cornerRadius: (size + 2) * 0.22, style: .continuous))
        } else {
            Image(systemName: provider.iconName)
                .font(.system(size: size, weight: .semibold))
        }
    }

    /// The vendor app that carries this provider's mark, if the user has it.
    private static func bundleID(for provider: AIProvider) -> String? {
        switch provider {
        case .openAI, .chatGPTBridge: return "com.openai.chat"
        case .anthropic, .claudeBridge, .claudeCode:
            return "com.anthropic.claudefordesktop"
        case .googleGemini: return "com.google.Gemini"
        case .onDevice, .ollama, .openAICompatible, .kimi, .shortcuts: return nil
        }
    }

    /// Cached: these are read while drawing rows, and hitting LaunchServices per frame is
    /// the kind of small cost that shows up as a stutter in a list.
    private static var cache: [String: NSImage?] = [:]

    static func appIcon(for provider: AIProvider) -> NSImage? {
        guard let bundleID = bundleID(for: provider) else { return nil }
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = icon
        return icon
    }
}

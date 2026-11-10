// ProviderContextChip.swift
// Context-Dock
//
// Compact provider/model and context-fill meter chip (#335).
//
// Approved design: compact provider/model + small meter + percent.
// One shared-shell component for bottom Corner and centred launcher,
// reflecting the current scope’s actual routed provider/model and turn.
//
// Display-only: consumes existing engine usage/context-budget data.
// Unknown usage remains neutral.

import SwiftUI

struct ProviderContextChip: View {
    var scope: GeneralChatScope? = nil
    var compact: Bool = false

    @ObservedObject private var usageStore = ProviderContextUsageStore.shared
    @ObservedObject private var settings = AppSettings.shared

    private var snapshot: ScopeContextUsageSnapshot {
        usageStore.snapshot(for: scope)
    }

    private var percentText: String {
        if let pct = snapshot.percent {
            return "\(Int(round(pct)))%"
        }
        return "—%"
    }

    private var meterFillFraction: CGFloat {
        if let pct = snapshot.percent {
            return CGFloat(min(1.0, max(0.0, pct / 100.0)))
        }
        return 0.0
    }

    private var meterColor: Color {
        guard let pct = snapshot.percent else {
            return Color.secondary.opacity(0.3)
        }
        if pct >= 90.0 {
            return Color.red
        } else if pct >= 75.0 {
            return Color.orange
        }
        return Color.accentColor
    }

    var body: some View {
        Menu {
            menuButtons
        } label: {
            chipLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(accessibilityHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var menuButtons: some View {
        ForEach(AIProvider.allCases) { provider in
            Button {
                settings.selectedAIProvider = provider
            } label: {
                if provider == settings.selectedAIProvider {
                    Label(provider.displayName, systemImage: "checkmark")
                } else {
                    Text(provider.displayName)
                }
            }
        }
    }

    private var chipLabel: some View {
        HStack(spacing: 5) {
            AIProviderIcon(provider: snapshot.provider, size: 12)

            Text(snapshot.compactModel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)

            meterView

            Text(percentText)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(snapshot.isUnknown ? Color.secondary.opacity(0.55) : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
        )
        .contentShape(Capsule(style: .continuous))
    }

    private var meterView: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.12))
                .frame(width: 24, height: 4)

            if !snapshot.isUnknown {
                Capsule(style: .continuous)
                    .fill(meterColor)
                    .frame(width: max(2.0, 24.0 * meterFillFraction), height: 4)
            }
        }
        .frame(width: 24, height: 4)
    }

    private var accessibilityDescription: String {
        if let pct = snapshot.percent {
            return "\(snapshot.provider.shortName) \(snapshot.compactModel), context window \(Int(round(pct)))% full"
        }
        return "\(snapshot.provider.shortName) \(snapshot.compactModel), context window usage unknown"
    }

    private var accessibilityHelp: String {
        if let used = snapshot.usedTokens {
            let maxK = snapshot.maxContextTokens >= 1000 ? "\(snapshot.maxContextTokens / 1000)k" : "\(snapshot.maxContextTokens)"
            return "\(snapshot.provider.displayName) (\(snapshot.modelName)): \(used) / \(maxK) tokens (\(percentText)) — click to switch provider"
        }
        return "\(snapshot.provider.displayName) (\(snapshot.modelName)): context usage unknown — click to switch provider"
    }
}

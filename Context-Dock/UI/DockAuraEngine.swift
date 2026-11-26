// Context-Dock/UI/DockAuraEngine.swift
// Context-Dock
//
// Unified Dock & 680×440 Result Sheet Color / Rim Glow Engine (Step 4).
// Driven by `.doraxpack` v3 `appearance: { tint: "#HEX", glow: "none|soft|pulse|breathe|orbit" }`,
// active Notch Live Activities (timers / recordings), or reactive Hook alerts.
//
// Respects:
// - Global user toggle & intensity (`doraxAuraEnabled`, `doraxAuraIntensity`)
// - macOS Accessibility Reduce Motion (`accessibilityDisplayShouldReduceMotion`):
//   downgrades animated modes (`pulse`, `breathe`, `orbit`) to a calm static tint.

import AppKit
import Combine
import SwiftUI

struct DockAuraSource: Equatable, Identifiable {
    let id: String
    let tintHex: String
    let glow: DoraxGlowStyle
    let priority: Int
    let expiresAt: Date?
}

@MainActor
final class DockAuraEngine: ObservableObject {
    static let shared = DockAuraEngine()

    private static let enabledKey = "doraxAuraEnabled"
    private static let intensityKey = "doraxAuraIntensity"

    @Published private(set) var sources: [DockAuraSource] = []
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    @Published var intensity: Double {
        didSet { UserDefaults.standard.set(intensity, forKey: Self.intensityKey) }
    }

    private var expiryTasks: [String: Task<Void, Never>] = [:]

    private init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        let savedIntensity = UserDefaults.standard.double(forKey: Self.intensityKey)
        self.intensity = savedIntensity > 0 ? min(1.0, max(0.1, savedIntensity)) : 0.75
    }

    /// The highest-priority non-expired aura source currently active.
    var activeSource: DockAuraSource? {
        guard isEnabled else { return nil }
        let now = Date()
        return sources
            .filter { $0.expiresAt == nil || $0.expiresAt! > now }
            .max { a, b in a.priority < b.priority }
    }

    /// Effective glow style after accounting for Reduce Motion & global toggle.
    func effectiveGlow(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) -> DoraxGlowStyle {
        guard isEnabled, let src = activeSource else { return .none }
        let normalized = src.glow.normalized
        if normalized == .none { return .none }
        if reduceMotion && (normalized == .pulse || normalized == .breathe || normalized == .orbit) {
            return .soft
        }
        return normalized
    }

    var activeColor: Color? {
        guard isEnabled, let hex = activeSource?.tintHex else { return nil }
        return Self.color(fromHex: hex)
    }

    func activate(
        id: String,
        appearance: DoraxPackAppearance,
        priority: Int = 50,
        ttlSeconds: TimeInterval? = nil
    ) {
        let style = appearance.glow.normalized
        guard style != .none, let tint = appearance.tint, !tint.isEmpty else {
            deactivate(id: id)
            return
        }
        expiryTasks[id]?.cancel()
        let expiresAt = ttlSeconds.map { Date().addingTimeInterval($0) }
        let source = DockAuraSource(
            id: id, tintHex: tint, glow: style, priority: priority, expiresAt: expiresAt)
        sources.removeAll { $0.id == id }
        sources.append(source)

        if let ttl = ttlSeconds, ttl > 0 {
            expiryTasks[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.deactivate(id: id)
            }
        }
    }

    func deactivate(id: String) {
        expiryTasks[id]?.cancel()
        expiryTasks[id] = nil
        sources.removeAll { $0.id == id }
    }

    func clearAll() {
        expiryTasks.values.forEach { $0.cancel() }
        expiryTasks.removeAll()
        sources.removeAll()
    }

    // MARK: - Hex Color Parser

    static func color(fromHex raw: String) -> Color? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6 || cleaned.count == 8,
              let value = UInt64(cleaned, radix: 16)
        else { return nil }

        if cleaned.count == 6 {
            let r = Double((value >> 16) & 0xFF) / 255.0
            let g = Double((value >> 8) & 0xFF) / 255.0
            let b = Double(value & 0xFF) / 255.0
            return Color(red: r, green: g, blue: b)
        } else {
            let r = Double((value >> 24) & 0xFF) / 255.0
            let g = Double((value >> 16) & 0xFF) / 255.0
            let b = Double((value >> 8) & 0xFF) / 255.0
            let a = Double(value & 0xFF) / 255.0
            return Color(red: r, green: g, blue: b, opacity: a)
        }
    }
}

// MARK: - Animated Rim Glow ViewModifier

struct DockAuraRimModifier: ViewModifier {
    var cornerRadius: CGFloat = 22
    var overrideAppearance: DoraxPackAppearance? = nil

    @ObservedObject private var aura = DockAuraEngine.shared
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion
    @State private var phase: Double = 0

    private var resolvedColor: Color? {
        if let hex = overrideAppearance?.tint, let c = DockAuraEngine.color(fromHex: hex) {
            return c
        }
        return aura.activeColor
    }

    private var resolvedGlow: DoraxGlowStyle {
        let reduce = envReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let override = overrideAppearance {
            let norm = override.glow.normalized
            if !aura.isEnabled || norm == .none { return .none }
            if reduce && (norm == .pulse || norm == .breathe || norm == .orbit) { return .soft }
            return norm
        }
        return aura.effectiveGlow(reduceMotion: reduce)
    }

    func body(content: Content) -> some View {
        let glow = resolvedGlow
        let color = resolvedColor
        let strength = aura.intensity

        content
            .overlay {
                if let color, glow != .none {
                    rimOverlay(color: color, glow: glow, strength: strength)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { startAnimationIfNeeded(for: glow) }
            .onChange(of: glow) { _, newGlow in startAnimationIfNeeded(for: newGlow) }
    }

    @ViewBuilder
    private func rimOverlay(color: Color, glow: DoraxGlowStyle, strength: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch glow {
        case .none, .off:
            EmptyView()
        case .soft, .ambient:
            shape
                .strokeBorder(color.opacity(0.45 * strength), lineWidth: 1.5)
                .shadow(color: color.opacity(0.28 * strength), radius: 10)
        case .pulse, .burst:
            let pulseOpacity = (0.35 + 0.55 * phase) * strength
            shape
                .strokeBorder(color.opacity(pulseOpacity), lineWidth: 2.0)
                .shadow(color: color.opacity(pulseOpacity * 0.7), radius: 14)
        case .breathe:
            let breatheOpacity = (0.25 + 0.45 * phase) * strength
            shape
                .strokeBorder(color.opacity(breatheOpacity), lineWidth: 1.75)
                .shadow(color: color.opacity(breatheOpacity * 0.65), radius: 12)
        case .orbit:
            shape
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            color.opacity(0.15 * strength),
                            color.opacity(0.85 * strength),
                            color.opacity(0.30 * strength),
                            color.opacity(0.15 * strength),
                        ]),
                        center: .center,
                        angle: .degrees(phase * 360)
                    ),
                    lineWidth: 2.0
                )
                .shadow(color: color.opacity(0.32 * strength), radius: 12)
        }
    }

    private func startAnimationIfNeeded(for glow: DoraxGlowStyle) {
        switch glow {
        case .pulse, .burst:
            phase = 0
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                phase = 1
            }
        case .breathe:
            phase = 0
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                phase = 1
            }
        case .orbit:
            phase = 0
            withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                phase = 1
            }
        default:
            phase = 0
        }
    }
}

extension View {
    func doraxAuraRim(cornerRadius: CGFloat = 22, appearance: DoraxPackAppearance? = nil) -> some View {
        modifier(DockAuraRimModifier(cornerRadius: cornerRadius, overrideAppearance: appearance))
    }
}

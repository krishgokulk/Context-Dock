import AppKit
import Foundation
import SwiftUI

enum GlobalContextTypingPhase: Equatable {
    case idle
    case typing
    case matched
    case expandable
    case expanded
}

/// The two visual states of the Global Context surface. Derived ONLY from
/// `GlobalContextTypingSnapshot.phase` (the single expansion source of truth) —
/// never from query text, selected row, match dock contents, or result count.
enum GlobalContextVisualState: Equatable {
    case compactTyping
    case expandedNavigation
}

struct GlobalContextTopMatch: Identifiable, Equatable {
    enum Kind: Equatable {
        case installedApp
        case runningApp
        case globalCommand
        case cachedMenuApp
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String?
    let bundleID: String?
    let iconKey: String?
    let query: String
    let cachedMenuMatchCount: Int
    let isExpandable: Bool
}

struct MatchDockIcon: Identifiable, Equatable {
    let id: String
    let bundleID: String?
    let title: String
    let icon: NSImage
    let isRunning: Bool
    let isExpandable: Bool
    let score: Double
    let isExactAppPrefix: Bool

    static func == (lhs: MatchDockIcon, rhs: MatchDockIcon) -> Bool {
        lhs.id == rhs.id
            && lhs.bundleID == rhs.bundleID
            && lhs.title == rhs.title
            && lhs.isRunning == rhs.isRunning
            && lhs.isExpandable == rhs.isExpandable
            && lhs.score == rhs.score
            && lhs.isExactAppPrefix == rhs.isExactAppPrefix
    }
}

struct GlobalContextTypingSnapshot: Equatable {
    var query: String = ""
    var phase: GlobalContextTypingPhase = .idle
    var topMatch: GlobalContextTopMatch?
    var matchDockIcons: [MatchDockIcon] = []
    var matchDockOverflowCount: Int = 0
    var preparedResultsVersion: Int = 0

    var shouldShowOnlyTopMatch: Bool {
        switch phase {
        case .typing, .matched, .expandable:
            return true
        case .idle, .expanded:
            return false
        }
    }
}

struct ContextMatchDock: View {
    enum Phase: Equatable {
        case idle
        case matching
    }

    let phase: Phase
    let icons: [MatchDockIcon]
    let overflowCount: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(icons) { item in
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: item.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .accessibilityLabel(accessibilityLabel(for: item))

                    if item.isRunning && phase == .idle {
                        Circle()
                            .fill(Color.green.opacity(0.72))
                            .frame(width: 4.5, height: 4.5)
                            .offset(x: 2, y: 2)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if item.isExpandable && phase == .idle {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundStyle(.secondary.opacity(0.7))
                            .offset(x: 3, y: 3)
                    }
                }
                .id(item.id)
                .transition(.opacity)
                .help(accessibilityLabel(for: item))
            }

            if overflowCount > 0 {
                Text("+\(overflowCount)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.65))
                    .monospacedDigit()
                    .frame(width: 24, alignment: .center)
                    .accessibilityLabel("\(overflowCount) more matches")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, icons.isEmpty && overflowCount == 0 ? 0 : 8)
        .padding(.vertical, 4)
        .frame(height: 30, alignment: .center)
        .fixedSize(horizontal: true, vertical: false)
        .opacity(phase == .matching ? 0.74 : 1.0)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7)
        )
        .animation(.easeOut(duration: 0.08), value: icons.map(\.id))
        .animation(.easeOut(duration: 0.08), value: overflowCount > 0)
    }

    private func accessibilityLabel(for item: MatchDockIcon) -> String {
        var parts = [item.title]
        if item.isRunning {
            parts.append("running")
        }
        if item.isExpandable {
            parts.append("expandable")
        }
        return parts.joined(separator: ", ")
    }
}

struct GlobalContextPreparedResults: Equatable {
    let query: String
    let appDocumentIDs: [String]
    let menuDocumentIDs: [String]

    // Backward-compat placeholders for older call sites expecting navigation metadata
    // These are optional and default to nil so existing logic can gate on availability.
    let navigationState: GlobalGroupedListNavigationState? = nil
    let state: GlobalGroupedListNavigationState? = nil

    var isEmpty: Bool {
        appDocumentIDs.isEmpty && menuDocumentIDs.isEmpty
    }

    static func == (lhs: GlobalContextPreparedResults, rhs: GlobalContextPreparedResults) -> Bool {
        return lhs.query == rhs.query
            && lhs.appDocumentIDs == rhs.appDocumentIDs
            && lhs.menuDocumentIDs == rhs.menuDocumentIDs
    }
}

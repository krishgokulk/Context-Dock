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

                    if item.isRunning {
                        Circle()
                            .fill(Color.green.opacity(0.9))
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: 2)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.isExpandable {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                            .offset(x: 4, y: -4)
                    }
                }
                .id(item.id)
                .transition(.opacity)
                .help(accessibilityLabel(for: item))
            }

            if overflowCount > 0 {
                Text("+\(overflowCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 26, alignment: .center)
                    .accessibilityLabel("\(overflowCount) more matches")
                    .transition(.opacity)
            }
        }
        .frame(width: 128, height: 24, alignment: .trailing)
        .animation(.easeInOut(duration: 0.10), value: icons)
        .animation(.easeInOut(duration: 0.10), value: overflowCount)
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

    var isEmpty: Bool {
        appDocumentIDs.isEmpty && menuDocumentIDs.isEmpty
    }
}

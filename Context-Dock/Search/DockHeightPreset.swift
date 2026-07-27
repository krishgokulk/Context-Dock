import CoreGraphics

enum DockHeightPreset: Equatable {
    case compact
    case standard
    case large
    case expanded

    var minimumHeight: CGFloat {
        switch self {
        case .compact: return 64
        case .standard: return 128
        case .large: return 460
        case .expanded: return 620
        }
    }

    var maximumHeight: CGFloat {
        switch self {
        case .compact: return 120
        case .standard: return 420
        case .large: return 620
        case .expanded: return 760
        }
    }

    var stabilizesResize: Bool {
        switch self {
        case .compact, .standard:
            return true
        case .large, .expanded:
            return false
        }
    }

    func clampedHeight(_ proposed: CGFloat) -> CGFloat {
        min(max(proposed, minimumHeight), maximumHeight)
    }
}

enum DockSurfaceMode: Equatable {
    case globalContext
    case contextDock
    case generalChat
    case contextDockChat
    case mediaDock
}

enum DockResizeReason {
    case modeChanged
    case panelChanged
    case rowLayoutChanged
    case resultsChanged
    case chatChanged
    case contentSettled
    case explicit

    var isTypingOrContentRefresh: Bool {
        switch self {
        case .resultsChanged, .chatChanged, .contentSettled:
            return true
        case .modeChanged, .panelChanged, .rowLayoutChanged, .explicit:
            return false
        }
    }
}

struct DockHeightMetrics {
    var surfaceMode: DockSurfaceMode
    var statusBarHeight: CGFloat
    var contextHeight: CGFloat
    var searchBarHeight: CGFloat
    var indexingBarHeight: CGFloat
    var finderSearchPanelHeight: CGFloat
    var contextChipHeight: CGFloat
    var aiMessageCount: Int
    var showsContextDockAppPanel: Bool
    var compactSmartScope: Bool
    /// Panel height reserved for a compact smart scope. Defaults to 450, but the window
    /// switcher shrinks it to a compact bar when idle (app row only, nothing selected).
    var compactScopePanelHeight: CGFloat = 450
    var mediaHasDuration: Bool
    var contextDockChatMessageCount: Int
    var listViewDockHeight: CGFloat
    var selectionScopeAIChat: Bool = false
    var resultCount: Int
    var loadingApps: Bool
    var l1ResultsReservedHeight: CGFloat
    var measuredChatContentHeight: CGFloat = 0
}

struct DockHeightPresetMetrics {
    var surfaceMode: DockSurfaceMode
    var usesVerticalListDockLayout: Bool
    var listViewDockHeight: CGFloat
    var selectionScopeAIChat: Bool = false
    var showsFinderSearchResultsPanel: Bool
    var showsContextDockAppPanel: Bool
    var compactSmartScope: Bool
    var resultCount: Int
    var loadingApps: Bool
    var searchBarExpanded: Bool
    var aiMessageCount: Int = 0
}

struct DockHeightResolver {
    static func resolvePreset(_ metrics: DockHeightPresetMetrics) -> DockHeightPreset {
        switch metrics.surfaceMode {
        case .mediaDock:
            return .compact
        case .generalChat:
            return metrics.aiMessageCount > 0 ? .expanded : .compact
        case .contextDockChat:
            return collapsedPreset(metrics)
        case .globalContext, .contextDock:
            if metrics.usesVerticalListDockLayout
                || metrics.listViewDockHeight > 0
                || metrics.selectionScopeAIChat
                || metrics.showsFinderSearchResultsPanel
                || metrics.showsContextDockAppPanel
                || metrics.compactSmartScope
                || metrics.resultCount > 0
                || metrics.loadingApps
            {
                return .large
            }
            return metrics.searchBarExpanded ? .standard : .compact
        }
    }

    private static func collapsedPreset(_ metrics: DockHeightPresetMetrics) -> DockHeightPreset {
        metrics.searchBarExpanded ? .standard : .compact
    }

    static func resolve(_ metrics: DockHeightMetrics) -> CGFloat {
        switch metrics.surfaceMode {
        case .generalChat:
            return generalChatHeight(metrics)
        case .contextDockChat:
            return contextDockChatHeight(metrics)
        case .globalContext:
            return searchSurfaceHeight(metrics)
        case .contextDock:
            return searchSurfaceHeight(metrics)
        case .mediaDock:
            return mediaDockHeight(metrics)
        }
    }

    private static func collapsedPillHeight(_ metrics: DockHeightMetrics) -> CGFloat {
        metrics.statusBarHeight
            + metrics.contextHeight
            + metrics.searchBarHeight
            + metrics.contextChipHeight
            + metrics.indexingBarHeight
    }

    /// Shared chat-area height for the chat modes. Driven by the MEASURED intrinsic height of the
    /// conversation (not a per-message estimate), so tall messages — approval cards, multi-line
    /// replies — are never clipped. Capped at 450 (scrolls beyond). 0 when there is no content.
    static func chatAreaHeight(measuredContentHeight: CGFloat) -> CGFloat {
        guard measuredContentHeight > 1 else { return 0 }
        return min(measuredContentHeight + 8, 450)
    }

    private static func generalChatHeight(_ metrics: DockHeightMetrics) -> CGFloat {
        let bars = metrics.statusBarHeight + metrics.searchBarHeight
        // Gate on real message count, not the measured height — otherwise a stale measurement from a
        // previous conversation keeps the window tall after Clear/Delete (which made it reposition).
        guard metrics.aiMessageCount > 0 else { return bars }
        let chatHeight = min(max(metrics.measuredChatContentHeight, 60), 450)
        return bars + chatHeight + 10
    }

    /// Chat-with-frontmost-app sheet. The window must reserve the chat area (the old resolver
    /// returned bars-only, so the sheet content was clipped to a sliver). Mirrors generalChat:
    /// armed-with-no-messages shows just the "Chat with X" row; otherwise grows with messages.
    private static func contextDockChatHeight(_ metrics: DockHeightMetrics) -> CGFloat {
        let bars = metrics.statusBarHeight + metrics.searchBarHeight
        // Gate on real message count (ignore stale measured) so Clear/Exit collapses to the pill.
        guard metrics.contextDockChatMessageCount > 0 else { return bars }
        // Fixed header (~52) above a scroll capped at 400; measured is the message height only.
        let header: CGFloat = 52
        let scroll = min(max(metrics.measuredChatContentHeight, 60), 400)
        return bars + header + scroll + 18
    }

    private static func mediaDockHeight(_ metrics: DockHeightMetrics) -> CGFloat {
        // Constant height regardless of whether the track reports a duration, so
        // the Media Dock never resizes mid-playback and switching into it from
        // another mode animates smoothly instead of snapping between sizes.
        return metrics.statusBarHeight + MediaDockSurface.surfaceHeight + 12
    }

    private static func searchSurfaceHeight(_ metrics: DockHeightMetrics) -> CGFloat {
        let pinnedAppsHeight: CGFloat = 0

        if metrics.showsContextDockAppPanel {
            let panelHeight: CGFloat = 480
            let panelGap: CGFloat = 10
            return metrics.statusBarHeight + pinnedAppsHeight + metrics.searchBarHeight
                + panelHeight + panelGap
        }

        if metrics.compactSmartScope {
            let panelHeight: CGFloat = metrics.compactScopePanelHeight
            let panelGap: CGFloat = 8
            return metrics.statusBarHeight + pinnedAppsHeight + metrics.searchBarHeight
                + panelHeight + panelGap
        }

        if metrics.finderSearchPanelHeight > 0 {
            return metrics.statusBarHeight + pinnedAppsHeight + metrics.searchBarHeight
                + metrics.finderSearchPanelHeight + 14
        }

        if metrics.selectionScopeAIChat {
            let chatHeight = min(max(metrics.measuredChatContentHeight, 60), 450)
            return metrics.statusBarHeight + pinnedAppsHeight + metrics.searchBarHeight
                + chatHeight + 10
        }

        if metrics.listViewDockHeight > 0 {
            return metrics.statusBarHeight + pinnedAppsHeight + metrics.listViewDockHeight + 12
        }

        if metrics.resultCount > 0 {
            let resultHeight =
                metrics.l1ResultsReservedHeight > 0
                ? metrics.l1ResultsReservedHeight
                : l1ResultsHeight(for: metrics.resultCount)
            return metrics.statusBarHeight + metrics.contextHeight + pinnedAppsHeight
                + metrics.searchBarHeight + metrics.contextChipHeight + metrics.indexingBarHeight
                + resultHeight + 10
        }

        if metrics.loadingApps {
            return metrics.statusBarHeight + metrics.contextHeight + pinnedAppsHeight
                + metrics.searchBarHeight + metrics.contextChipHeight + metrics.indexingBarHeight
                + 60
        }

        return metrics.statusBarHeight + metrics.contextHeight + pinnedAppsHeight
            + metrics.searchBarHeight + metrics.contextChipHeight + metrics.indexingBarHeight
    }

    static func l1ResultsHeight(for resultCount: Int) -> CGFloat {
        guard resultCount > 0 else { return 0 }
        let headerHeight: CGFloat = 32
        let rowHeight: CGFloat = 58
        let verticalPadding: CGFloat = 12
        let contentHeight = headerHeight + CGFloat(resultCount) * rowHeight + verticalPadding
        let minimumHeight: CGFloat = resultCount <= 2 ? contentHeight : 112
        return min(max(contentHeight, minimumHeight), 450)
    }
}

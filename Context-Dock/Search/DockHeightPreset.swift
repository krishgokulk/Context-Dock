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
    var mediaHasDuration: Bool
    var contextDockChatMessageCount: Int
    var listViewDockHeight: CGFloat
    var resultCount: Int
    var loadingApps: Bool
    var l1ResultsReservedHeight: CGFloat
}

struct DockHeightPresetMetrics {
    var surfaceMode: DockSurfaceMode
    var usesVerticalListDockLayout: Bool
    var listViewDockHeight: CGFloat
    var showsFinderSearchResultsPanel: Bool
    var showsContextDockAppPanel: Bool
    var compactSmartScope: Bool
    var resultCount: Int
    var loadingApps: Bool
    var searchBarExpanded: Bool
}

struct DockHeightResolver {
    static func resolvePreset(_ metrics: DockHeightPresetMetrics) -> DockHeightPreset {
        switch metrics.surfaceMode {
        case .mediaDock:
            return .compact
        case .generalChat:
            return .expanded
        case .contextDockChat:
            return collapsedPreset(metrics)
        case .globalContext, .contextDock:
            if metrics.usesVerticalListDockLayout
                || metrics.listViewDockHeight > 0
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
            return collapsedPillHeight(metrics)
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

    private static func generalChatHeight(_ metrics: DockHeightMetrics) -> CGFloat {
        let chatHeight: CGFloat = 620
        return metrics.statusBarHeight + metrics.searchBarHeight + chatHeight + 10
    }

    private static func mediaDockHeight(_ metrics: DockHeightMetrics) -> CGFloat {
        let mediaPillHeight: CGFloat =
            metrics.mediaHasDuration ? 70 : metrics.searchBarHeight
        return metrics.statusBarHeight + mediaPillHeight + 12
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
            let panelHeight: CGFloat = 450
            let panelGap: CGFloat = 8
            return metrics.statusBarHeight + pinnedAppsHeight + metrics.searchBarHeight
                + panelHeight + panelGap
        }

        if metrics.finderSearchPanelHeight > 0 {
            return metrics.statusBarHeight + pinnedAppsHeight + metrics.searchBarHeight
                + metrics.finderSearchPanelHeight + 14
        }

        if metrics.listViewDockHeight > 0 {
            return metrics.statusBarHeight + pinnedAppsHeight + metrics.listViewDockHeight + 12
        }

        if metrics.resultCount > 0 {
            let resultHeight =
                metrics.l1ResultsReservedHeight > 0 ? metrics.l1ResultsReservedHeight : 450
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
}

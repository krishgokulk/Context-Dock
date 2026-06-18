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
    var statusBarHeight: CGFloat
    var contextHeight: CGFloat
    var searchBarHeight: CGFloat
    var indexingBarHeight: CGFloat
    var finderSearchPanelHeight: CGFloat
    var contextChipHeight: CGFloat
    var aiModeActive: Bool
    var aiMessageCount: Int
    var showsContextDockAppPanel: Bool
    var compactSmartScope: Bool
    var mediaLayerVisible: Bool
    var mediaHasDuration: Bool
    var contextDockChatVisible: Bool
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
        case .contextDockChat, .generalChat:
            return .expanded
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

    static func resolve(_ metrics: DockHeightMetrics) -> CGFloat {
        let pinnedAppsHeight: CGFloat = 0

        if metrics.aiModeActive {
            let aiChatHeight: CGFloat =
                metrics.aiMessageCount == 0
                ? 0
                : min(CGFloat(metrics.aiMessageCount) * 76, 400)
            let aiLoadingHeight: CGFloat = metrics.aiMessageCount == 0 ? 0 : 48
            return metrics.statusBarHeight + pinnedAppsHeight + metrics.searchBarHeight
                + aiChatHeight + aiLoadingHeight + 12
        }

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

        if metrics.mediaLayerVisible {
            let mediaPillHeight: CGFloat =
                metrics.mediaHasDuration ? 70 : metrics.searchBarHeight
            return metrics.statusBarHeight + mediaPillHeight + 12
        }

        if metrics.contextDockChatVisible {
            let messageHeight = min(CGFloat(max(metrics.contextDockChatMessageCount, 1)) * 92, 400)
            let loadingHeight: CGFloat = 54
            let headerHeight: CGFloat = metrics.contextDockChatMessageCount == 0 ? 0 : 42
            let chatHeight = min(messageHeight + loadingHeight + headerHeight + 26, 500)
            return metrics.statusBarHeight + pinnedAppsHeight + metrics.searchBarHeight
                + chatHeight + 10
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

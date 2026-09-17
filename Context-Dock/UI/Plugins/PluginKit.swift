// Context-Dock
//
// The kit's tokens. Every component's size and spacing comes from here, so a manifest can
// pick and bind but never style, and so `PluginSizing` and the views can never disagree about
// how tall something is — they read the same numbers. Spec §6.

import CoreGraphics
import Foundation

enum PluginKit {
    static let gap: CGFloat = 8
    static let cardPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 12
    static let sectionHeaderHeight: CGFloat = 24
    static let diagnosticHeight: CGFloat = 32

    static func rowHeight(_ traits: HostTraits) -> CGFloat {
        traits.widthClass == .compact ? 38 : 44
    }

    /// The height of a component, whatever it holds. A row is a row's height whether it
    /// carries one line or a thumbnail and two — the kit decides, not the content, which is
    /// what keeps this arithmetic rather than a measurement.
    static func leafHeight(_ component: String, traits: HostTraits) -> CGFloat {
        let compact = traits.widthClass == .compact
        switch component {
        case "row", "fileRow": return rowHeight(traits)
        case "checkRow": return compact ? 32 : 36
        case "eventRow": return compact ? 44 : 52
        case "activityRow": return compact ? 36 : 40
        case "compareRow": return compact ? 40 : 46
        case "header": return 40
        case "title": return 22
        case "subtitle", "body", "liveText": return 18
        case "caption": return 14
        case "markdown": return compact ? 72 : 96
        case "stat": return 52
        case "divider": return 9
        case "emptyState": return compact ? 96 : 120
        case "loading": return compact ? 72 : 96
        case "button", "buttonRow", "iconButton", "toggle": return 32
        case "stateButton": return 34
        case "slider": return 36
        case "tag", "statusBadge": return 22
        case "chipRow": return 26
        case "segment": return 28
        case "progress": return 18
        case "timer": return 24
        case "waveform": return 28
        case "pulse": return 12
        case "mediaCard": return compact ? 84 : 96
        // A grid cell is a thumbnail's worth of space; the two share a height so a grid that
        // names no cell template is the same size as one that names the obvious cell.
        case "cell", "thumbnail": return compact ? 44 : 56
        case "avatar": return 36
        case "textField": return 32
        case "searchField": return 34
        case "dropzone": return compact ? 72 : 88
        case "ai": return compact ? 56 : 64
        case "native": return rowHeight(traits)
        default: return diagnosticHeight
        }
    }

    /// Spec §5: 4–6 columns in the dock sheet, 2–3 in the corner.
    static func gridColumns(_ declared: Int, traits: HostTraits) -> Int {
        let wanted = max(1, declared)
        return traits.widthClass == .compact ? min(wanted, 3) : min(wanted, 6)
    }
}

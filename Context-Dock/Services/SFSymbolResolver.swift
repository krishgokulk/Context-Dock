import AppKit
import Foundation

enum SFSymbolResolver {
    static func validSymbol(_ raw: String?, fallback: String = "gearshape") -> String {
        let symbol = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbol.isEmpty else { return fallback }
        if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            return symbol
        }
        return fallback
    }

    static func menuSymbol(title rawTitle: String, path rawPath: [String], isAppleMenu: Bool) -> String {
        let title = normalized(rawTitle)
        let parts = rawPath.map(normalized).filter { !$0.isEmpty }
        let parent = parts.dropLast().last ?? parts.first ?? ""
        let path = parts.joined(separator: " ")

        let resolved: String
        if isAppleMenu || parts.first == "apple" {
            resolved = appleMenuSymbol(title: title)
        } else if parent == "file" || path.hasPrefix("file ") {
            resolved = fileMenuSymbol(title: title)
        } else if parent == "edit" || path.hasPrefix("edit ") {
            resolved = editMenuSymbol(title: title)
        } else if parent == "view" || path.hasPrefix("view ") {
            resolved = viewMenuSymbol(title: title)
        } else if parent == "window" || path.hasPrefix("window ") || path.contains(" window ") {
            resolved = windowMenuSymbol(title: title)
        } else if parent == "format" || path.hasPrefix("format ") {
            resolved = formatMenuSymbol(title: title)
        } else if parent == "run" || path.hasPrefix("run ") {
            resolved = runMenuSymbol(title: title)
        } else if parent == "product" || path.hasPrefix("product ") {
            resolved = productMenuSymbol(title: title)
        } else {
            resolved = genericMenuSymbol(title: title, path: path, parent: parent)
        }
        return validSymbol(resolved, fallback: "menubar.rectangle")
    }

    static func systemSettingsPaneSymbol(title rawTitle: String) -> String {
        let title = normalized(rawTitle)
        let resolved: String
        if title.contains("accessibility") { resolved = "accessibility" }
        else if title.contains("appearance") { resolved = "circle.lefthalf.filled" }
        else if title.contains("battery") { resolved = "battery.100percent" }
        else if title.contains("bluetooth") { resolved = "bluetooth" }
        else if title.contains("desktop") || title.contains("dock") { resolved = "dock.rectangle" }
        else if title.contains("display") { resolved = "sun.max" }
        else if title.contains("family") { resolved = "person.2.fill" }
        else if title.contains("focus") { resolved = "moon.fill" }
        else if title.contains("game center") { resolved = "gamecontroller.fill" }
        else if title == "general" { resolved = "gearshape" }
        else if title.contains("icloud") { resolved = "icloud.fill" }
        else if title.contains("internet account") { resolved = "at" }
        else if title.contains("keyboard") { resolved = "keyboard" }
        else if title.contains("lock screen") { resolved = "lock.fill" }
        else if title.contains("menu bar") { resolved = "menubar.rectangle" }
        else if title.contains("network") { resolved = "network" }
        else if title.contains("notification") { resolved = "bell.badge.fill" }
        else if title.contains("printer") || title.contains("scanner") { resolved = "printer.fill" }
        else if title.contains("privacy") || title.contains("security") { resolved = "hand.raised.fill" }
        else if title.contains("screen time") { resolved = "hourglass" }
        else if title.contains("siri") { resolved = "waveform.circle.fill" }
        else if title.contains("sound") { resolved = "speaker.wave.2.fill" }
        else if title.contains("spotlight") { resolved = "magnifyingglass" }
        else if title.contains("touch id") || title.contains("password") { resolved = "touchid" }
        else if title.contains("trackpad") { resolved = "rectangle.and.hand.point.up.left.fill" }
        else if title.contains("user") || title.contains("group") { resolved = "person.2.fill" }
        else if title.contains("vpn") { resolved = "network.badge.shield.half.filled" }
        else if title.contains("wallet") || title.contains("apple pay") { resolved = "creditcard.fill" }
        else if title.contains("wallpaper") { resolved = "photo.fill" }
        else if title.contains("wi fi") || title.contains("wifi") { resolved = "wifi" }
        else { resolved = menuSymbol(title: rawTitle, path: ["View", rawTitle], isAppleMenu: false) }
        return validSymbol(resolved, fallback: "gearshape")
    }

    private static func appleMenuSymbol(title: String) -> String {
        if title.contains("about this mac") { return "laptopcomputer" }
        if title.contains("system settings") || title.contains("system preferences") { return "gearshape" }
        if title.contains("app store") { return "app.badge" }
        if title.contains("recent") { return "clock.arrow.circlepath" }
        if title.contains("force quit") { return "xmark.octagon" }
        if title.contains("sleep") { return "minus.circle" }
        if title.contains("restart") { return "arrow.clockwise" }
        if title.contains("shut down") || title.contains("shutdown") { return "power" }
        if title.contains("lock screen") { return "lock" }
        if title.contains("log out") { return "person.crop.circle.badge.xmark" }
        return "apple.logo"
    }

    private static func fileMenuSymbol(title: String) -> String {
        if title.contains("new") && title.contains("tab") { return "plus.square.on.square" }
        if title.contains("new") && title.contains("window") { return "macwindow.badge.plus" }
        if title == "new" || title.hasPrefix("new ") { return "plus.square" }
        if title.contains("open recent") { return "clock.arrow.circlepath" }
        if title.contains("open") { return "folder" }
        if title.contains("save as") { return "square.and.arrow.down.on.square" }
        if title.contains("save") { return "square.and.arrow.down" }
        if title.contains("export") { return "square.and.arrow.up" }
        if title.contains("import") { return "square.and.arrow.down" }
        if title.contains("print") { return "printer" }
        if title.contains("share") { return "square.and.arrow.up" }
        if title.contains("close") { return "xmark" }
        return "doc"
    }

    private static func editMenuSymbol(title: String) -> String {
        if title.contains("undo") { return "arrow.uturn.backward" }
        if title.contains("redo") { return "arrow.uturn.forward" }
        if title.contains("cut") { return "scissors" }
        if title.contains("copy") { return "doc.on.doc" }
        if title.contains("paste") { return "clipboard" }
        if title.contains("select all") { return "checkmark.circle" }
        if title.contains("find") || title.contains("search") { return "magnifyingglass" }
        if title.contains("spelling") || title.contains("grammar") { return "textformat.abc" }
        if title.contains("substitution") { return "textformat" }
        if title.contains("transform") { return "textformat.alt" }
        if title.contains("dictation") { return "mic" }
        if title.contains("emoji") { return "face.smiling" }
        if title.contains("writing tools") { return "apple.intelligence" }
        if title.contains("autofill") { return "text.badge.checkmark" }
        return "pencil"
    }

    private static func viewMenuSymbol(title: String) -> String {
        if title.contains("sidebar") { return "sidebar.left" }
        if title.contains("toolbar") { return "menubar.rectangle" }
        if title.contains("tab bar") { return "rectangle.topthird.inset.filled" }
        if title.contains("status") { return "rectangle.bottomthird.inset.filled" }
        if title.contains("actual size") { return "magnifyingglass" }
        if title.contains("zoom in") { return "plus.magnifyingglass" }
        if title.contains("zoom out") { return "minus.magnifyingglass" }
        if title.contains("full screen") { return "arrow.up.left.and.arrow.down.right" }
        if title.contains("reload") || title.contains("refresh") { return "arrow.clockwise" }
        return "eye"
    }

    private static func windowMenuSymbol(title: String) -> String {
        if title.contains("minimi") { return "minus.rectangle" }
        if title.contains("zoom") { return "arrow.up.left.and.arrow.down.right" }
        if title.contains("fill") || title == "centre" || title == "center" { return "rectangle.inset.filled" }
        if title.contains("move") && title.contains("resize") { return "arrow.up.left.and.arrow.down.right" }
        if title.contains("full screen") { return "rectangle.split.2x1" }
        if title.contains("cycle") { return "square.stack.3d.up" }
        if title.contains("bring all") { return "square.3.layers.3d.top.filled" }
        if title.contains("previous tab") { return "arrow.left.square" }
        if title.contains("next tab") { return "arrow.right.square" }
        if title.contains("merge") { return "rectangle.3.group" }
        return "macwindow"
    }

    private static func formatMenuSymbol(title: String) -> String {
        if title.contains("bold") { return "bold" }
        if title.contains("italic") { return "italic" }
        if title.contains("underline") { return "underline" }
        if title.contains("font") { return "textformat" }
        if title.contains("color") || title.contains("colour") { return "paintpalette" }
        if title.contains("align") { return "text.alignleft" }
        if title.contains("list") { return "list.bullet" }
        return "textformat"
    }

    private static func runMenuSymbol(title: String) -> String {
        if title.contains("debug") { return "ladybug" }
        if title.contains("stop") { return "stop.circle" }
        if title.contains("pause") { return "pause.circle" }
        if title.contains("continue") || title.contains("resume") { return "play.circle" }
        if title.contains("step") { return "arrow.turn.down.right" }
        return "play"
    }

    private static func productMenuSymbol(title: String) -> String {
        if title.contains("build") { return "hammer" }
        if title.contains("test") { return "checkmark.seal" }
        if title.contains("run") { return "play" }
        if title.contains("clean") { return "sparkles" }
        if title.contains("archive") { return "archivebox" }
        if title.contains("analyze") || title.contains("analyse") { return "waveform.path.ecg" }
        return "shippingbox"
    }

    private static func genericMenuSymbol(title: String, path: String, parent: String) -> String {
        if title == "close" || title.hasPrefix("close ") { return "xmark" }
        if title.contains("quit") { return "xmark.circle" }
        if title.contains("hide") { return "eye.slash" }
        if title.contains("show all") { return "eye" }
        if title.contains("recent") || path.contains("recent") { return "clock.arrow.circlepath" }
        if title.contains("history") || path.contains("history") { return "clock.arrow.circlepath" }
        if title.contains("search") || title.contains("find") { return "magnifyingglass" }
        if title.contains("bookmark") || title.contains("favorite") || title.contains("favourite") { return "bookmark" }
        if title.contains("reading list") { return "eyeglasses" }
        if title.contains("download") { return "arrow.down.circle" }
        if title.contains("desktop") { return "menubar.rectangle" }
        if title.contains("document") { return "doc.text" }
        if title.contains("home") { return "house" }
        if title.contains("library") { return "building.columns" }
        if title.contains("computer") { return "desktopcomputer" }
        if title.contains("airdrop") { return "antenna.radiowaves.left.and.right" }
        if title.contains("network") { return "network" }
        if title.contains("icloud") { return "icloud" }
        if title.contains("application") { return "app.badge" }
        if title.contains("utilit") { return "wrench.and.screwdriver" }
        if title.contains("folder") || path.contains("go ") { return "folder.fill" }
        if title.contains("back") { return "chevron.backward" }
        if title.contains("forward") { return "chevron.forward" }
        if title.contains("reload") || title.contains("refresh") { return "arrow.clockwise" }
        if title.contains("stop") { return "xmark.octagon" }
        if title.contains("reader") { return "doc.plaintext" }
        if title.contains("privacy") { return "hand.raised" }
        if title.contains("security") { return "lock.shield" }
        if title.contains("extension") { return "puzzlepiece" }
        if title.contains("password") { return "key" }
        if title.contains("address") || title.contains("location") { return "location" }
        if title.contains("map") || title.contains("directions") || title.contains("route") { return "map" }
        if title.contains("play") { return "play" }
        if title.contains("pause") { return "pause" }
        if title.contains("mute") { return "speaker.slash" }
        if title.contains("volume") { return "speaker.wave.2" }
        if title.contains("mail") || title.contains("email") { return "envelope" }
        if title.contains("message") { return "message" }
        if title.contains("call") { return "phone" }
        if title.contains("calendar") || title.contains("event") { return "calendar" }
        if title.contains("reminder") { return "checklist" }
        if title.contains("note") { return "note.text" }
        if title.contains("open with") { return "chevron.right.square" }
        if title.contains("open") { return "arrow.up.right.square" }
        if title.contains("bin") || title.contains("trash") { return "trash" }
        if title.contains("info") { return "info.circle" }
        if title.contains("rename") { return "pencil" }
        if title.contains("compress") || title.contains("archive") { return "archivebox" }
        if title.contains("duplicate") { return "plus.square.on.square" }
        if title.contains("alias") { return "arrow.triangle.branch" }
        if title.contains("quick look") { return "eye" }
        if title.contains("copy") { return "doc.on.doc" }
        if title.contains("share") { return "square.and.arrow.up" }
        if title.contains("tag") { return "tag" }
        if title.contains("service") { return "gearshape.2" }
        if title.contains("quick action") { return "bolt" }

        switch parent {
        case "file": return "doc"
        case "edit": return "pencil"
        case "view": return "eye"
        case "go": return "arrowshape.turn.up.right"
        case "bookmarks": return "bookmark"
        case "history": return "clock.arrow.circlepath"
        case "develop": return "hammer"
        case "help": return "questionmark.circle"
        case "services": return "gearshape.2"
        default: return "menubar.rectangle"
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation

struct ShortcutMenuCommand: Identifiable {
    let id: String
    let item: AXMenuItem
    let title: String
    let section: String
    let parentPath: String
    let shortcutDisplay: String?
    let score: Double

    private static func hasNativeShortcut(_ item: AXMenuItem) -> Bool {
        item.shortcutChar?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func shouldInclude(_ item: AXMenuItem) -> Bool {
        item.isEnabled || hasNativeShortcut(item) || item.resolvedFilePath != nil
    }

    static func commands(
        from items: [AXMenuItem],
        query: String,
        fallbackSourcePID: pid_t
    ) -> [ShortcutMenuCommand] {
        var commands: [ShortcutMenuCommand] = []
        commands.reserveCapacity(items.count)

        for (order, item) in items.enumerated() {
            guard item.children.isEmpty, shouldInclude(item) else { continue }
            let section = item.path.first ?? "Other"
            let parentPath = item.path.count > 2
                ? item.path.dropLast().dropFirst().joined(separator: " > ")
                : ""
            let haystack = ([item.title, item.shortcutDisplay ?? ""] + item.path)
                .joined(separator: " ")
                .lowercased()

            let sourcePID = item.sourcePID != 0 ? item.sourcePID : fallbackSourcePID
            let pathKey = item.path
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
                .joined(separator: ">")
            let id = "\(sourcePID)|\(pathKey)|\(item.shortcutDisplay ?? "")"
            commands.append(ShortcutMenuCommand(
                id: id,
                item: item,
                title: item.title,
                section: section,
                parentPath: parentPath,
                shortcutDisplay: item.shortcutDisplay,
                score: score(item: item, query: "", order: order)
            ))
        }

        return filtered(commands, query: query)
    }

    static func filtered(
        _ commands: [ShortcutMenuCommand],
        query: String
    ) -> [ShortcutMenuCommand] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return commands }

        return commands
            .enumerated()
            .compactMap { order, command -> ShortcutMenuCommand? in
                let haystack = ([command.title, command.shortcutDisplay ?? ""] + command.item.path)
                    .joined(separator: " ")
                    .lowercased()
                guard haystack.contains(q) else { return nil }
                return ShortcutMenuCommand(
                    id: command.id,
                    item: command.item,
                    title: command.title,
                    section: command.section,
                    parentPath: command.parentPath,
                    shortcutDisplay: command.shortcutDisplay,
                    score: score(item: command.item, query: q, order: order)
                )
            }
            .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private static func score(item: AXMenuItem, query: String, order: Int) -> Double {
        guard !query.isEmpty else { return -Double(order) }
        let title = item.title.lowercased()
        let path = item.path.joined(separator: " ").lowercased()
        let shortcut = (item.shortcutDisplay ?? "").lowercased()

        var value = 0.0
        if title == query { value += 10_000 }
        if title.hasPrefix(query) { value += 7_500 }
        if title.contains(query) { value += 5_000 }
        if path.contains(query) { value += 1_000 }
        if shortcut.contains(query) { value += 500 }
        value -= Double(item.path.count * 8)
        value -= Double(order) * 0.01
        return value
    }
}

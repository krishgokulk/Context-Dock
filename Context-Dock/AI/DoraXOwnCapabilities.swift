// DoraXOwnCapabilities.swift
// Context-Dock
//
// What DoraX itself can do, as records the ranker can see.
//
// Every other source in the index describes something else — an app's actions, its CLI, its
// menus. DoraX's own surfaces were invisible to it. `GlobalCommandCapabilities` registers
// commands for *execution* and `DoraXSurfaceSkills` describes the surfaces to a model in
// prose, but nothing put them where "given this sentence, what are the best things I can do
// about it?" could find them. So the assistant could run a Global Command it was told to run,
// and could never answer "you could add one".
//
// From the report that prompted this: Claude Desktop has a linked `claude` CLI. Asked to start
// a new chat, the honest answer includes that the CLI is there and that adding it to Global
// Commands would make it reachable from every scope, not just this chat. That sentence is a
// capability — surface `advisory`, runs nothing, changes what the user can do next — and it
// belongs in the index beside the rest rather than in a special case somewhere.
//
// Pure. Callers pass what is installed and what is linked; nothing here reads a singleton, so
// the ranking can be tested against a stated world rather than this machine's.
import Foundation

enum DoraXOwnCapabilities {

    /// DoraX's own surfaces, as the user would name them.
    ///
    /// These are not app capabilities and must never be attached to an app adapter — the
    /// clipboard is DoraX's, not Safari's. They carry no `app`, which is how the ranker
    /// already marks machine-wide things it must not demote for belonging to no app.
    static func surfaces() -> [CapabilityRecord] {
        [
            CapabilityRecord(
                id: "dorax.clipboard",
                kind: .capability,
                title: "Clipboard history",
                description: "What you copied recently, searchable, with multi-select and "
                    + "drag-out. DoraX's own store, not an app's.",
                keywords: ["clipboard", "copied", "paste", "history", "pasteboard"],
                isWrite: false,
                surface: .headless),
            CapabilityRecord(
                id: "dorax.preview",
                kind: .capability,
                title: "Preview window",
                description: "DoraX's own preview for a file, folder or page, without "
                    + "opening the owning app.",
                keywords: ["preview", "quicklook", "look", "peek", "show"],
                isWrite: false,
                // It does put a window on screen, and that is the cost the user is choosing
                // on — even though the window is DoraX's own.
                surface: .opensApp),
            CapabilityRecord(
                id: "dorax.cliScope",
                kind: .capability,
                title: "CLI tool scope",
                description: "A scope whose whole subject is one command-line tool, with its "
                    + "own transcript and approval trail.",
                keywords: ["cli", "terminal", "command", "shell", "tool"],
                isWrite: false,
                surface: .headless),
        ]
    }

    /// Global Commands the user has already set up, as things the ranker can propose.
    static func globalCommands(named names: [String]) -> [CapabilityRecord] {
        names.map { name in
            CapabilityRecord(
                id: "dorax.globalCommand." + name.lowercased()
                    .replacingOccurrences(of: " ", with: "-"),
                kind: .globalCommand,
                title: name,
                description: "A Global Command — reachable from every scope, not just one app.",
                keywords: name.lowercased().split(separator: " ").map(String.init),
                isWrite: true,
                surface: .headless)
        }
    }

    /// The suggestion the user asked for: an app has a CLI linked to its scope, and that CLI
    /// could be doing far more than one chat can ask of it.
    ///
    /// Advisory on purpose. It runs nothing and must never be `act`ed on — its whole value is
    /// being *said*, at the moment the user is discovering that the scope they are in is
    /// narrower than the tool behind it. Offering it as though it were an action would be the
    /// same mistake as the URL action that started all of this.
    ///
    /// Suggested only when the CLI is not already a Global Command, because telling somebody
    /// to add a thing they have added is noise, and noise is how advice gets ignored.
    static func linkCLISuggestions(
        appName: String, linkedCLINames: [String], existingGlobalCommands: [String]
    ) -> [CapabilityRecord] {
        let already = Set(existingGlobalCommands.map { $0.lowercased() })
        return linkedCLINames
            .filter { !already.contains($0.lowercased()) }
            .map { cli in
                CapabilityRecord(
                    id: "dorax.suggest.globalCommand." + cli.lowercased(),
                    app: appName,
                    kind: .globalCommand,
                    title: "Add \(cli) to Global Commands",
                    description: "\(cli) is linked to \(appName) here, so it is reachable only "
                        + "in this scope. As a Global Command it would be reachable from "
                        + "anywhere, with its own approval trail.",
                    keywords: [cli.lowercased(), "global", "command", "everywhere", "link"],
                    isWrite: false,
                    surface: .advisory)
            }
    }
}

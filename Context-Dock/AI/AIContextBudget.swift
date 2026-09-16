import Foundation

/// Relevance-ranked context fitting, replacing `String(text.prefix(N))`.
///
/// Two problems with a hard prefix cut. It keeps the *first* N characters rather than the
/// *relevant* ones — a query about `mole clean` gets the ASCII banner and the top-level
/// usage block while the `clean` section falls off the end. And it cuts mid-sentence,
/// mid-flag, sometimes mid-word, so the model reads a truncated flag as a real one.
///
/// This budgets instead: split the text into semantic chunks, score each against the
/// query, emit best-first until the budget is spent, and mark what was dropped so the
/// model knows the reference is partial rather than complete.
///
/// Budgets are in **characters, not tokens**. Anthropic's `count_tokens` is the only exact
/// answer and it costs a network round trip per call — unusable on a per-keystroke path.
/// Characters are a stable proxy for the ~4:1 English ratio, and the point here is
/// bounding a dump that was previously unbounded in relevance terms.
enum AIContextBudget {
    /// Characters of retrieved context a provider can absorb before it starts crowding out
    /// the conversation. Not the context window — the share of it this app is willing to
    /// spend on reference material for one turn.
    ///
    /// On-device Apple Intelligence gets a fraction of the cloud budget: its window is
    /// small enough that a 4 000-character help dump alone triggered "Exceeded model
    /// context window size", which is what the `suffix(4)` history trim was papering over.
    /// Attention is also O(n²·d) in sequence length, so an oversized budget costs answer
    /// quality on every provider, not just money.
    static func characterBudget(for provider: AIProvider) -> Int {
        switch provider {
        case .onDevice:
            return 1_500
        case .ollama, .openAICompatible, .shortcuts:
            // Local and bring-your-own endpoints: unknown window, frequently 8k or less.
            return 4_000
        case .anthropic, .openAI, .googleGemini, .kimi, .claudeBridge, .chatGPTBridge,
            .claudeCode:
            return 12_000
        }
    }

    /// Fits CLI `--help` output to `budget`, preferring the sections the query is about.
    ///
    /// A deep scan stores the tree as `--- cmd sub --help ---` delimited sections (see
    /// `TerminalPackageManager.scanDeepHelp`). Those delimiters are the natural chunk
    /// boundaries — one per subcommand — so a query mentioning a subcommand pulls that
    /// subcommand's real flags instead of whatever happened to be in the first N bytes.
    ///
    /// The top-level section always leads: it carries the usage line and the command list,
    /// which the model needs regardless of what was asked.
    static func fitHelpText(_ help: String, query: String, budget: Int) -> String {
        let text = help.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        guard text.count > budget else { return text }

        let chunks = helpChunks(text)
        guard chunks.count > 1 else {
            // Single unstructured block — no sections to choose between, so keep the head
            // but cut on a line boundary rather than mid-flag.
            return truncateAtLineBoundary(text, limit: budget) + "\n… (reference truncated)"
        }

        let terms = queryTerms(query)
        // Chunk 0 is the top-level help; it is not ranked, it is always included.
        let head = chunks[0]
        var remaining = budget - head.body.count
        var kept: [HelpChunk] = [head]

        let ranked = chunks.dropFirst()
            .map { chunk in (chunk: chunk, score: score(chunk, terms: terms)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                // Stable tie-break on original order, so an unrelated query still produces
                // a byte-identical prefix and the prompt cache keeps hitting.
                return lhs.chunk.index < rhs.chunk.index
            }

        var droppedCount = 0
        for entry in ranked {
            // A chunk that would blow the budget is skipped, not truncated — half a
            // subcommand's flag list is worse than none, because the model reads the
            // surviving half as complete.
            if entry.chunk.body.count <= remaining, entry.score > 0 || remaining > budget / 2 {
                kept.append(entry.chunk)
                remaining -= entry.chunk.body.count
            } else {
                droppedCount += 1
            }
        }

        // Restore document order — the model reads a help tree, not a ranking.
        var output = kept.sorted { $0.index < $1.index }.map(\.body).joined(separator: "\n\n")
        if droppedCount > 0 {
            output +=
                "\n\n… \(droppedCount) more subcommand section(s) not shown. "
                + "Run the tool's own `--help` for anything not listed here."
        }
        return output
    }

    /// Fits a plain reference block (adapter docs, capability text) to `budget`, cutting on
    /// a paragraph or line boundary and saying so.
    static func fitReference(_ text: String, budget: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > budget else { return trimmed }
        return truncateAtLineBoundary(trimmed, limit: budget) + "\n… (truncated)"
    }

    // MARK: - Chunking

    private struct HelpChunk {
        let index: Int
        let title: String
        let body: String
    }

    private static let sectionMarker = "\n--- "

    private static func helpChunks(_ text: String) -> [HelpChunk] {
        // Sections look like "--- mole clean --help ---\n<body>". Splitting on the leading
        // newline keeps the marker with its own body.
        let parts = text.components(separatedBy: sectionMarker)
        guard parts.count > 1 else {
            return [HelpChunk(index: 0, title: "", body: text)]
        }
        var chunks: [HelpChunk] = [HelpChunk(index: 0, title: "", body: parts[0])]
        for (offset, part) in parts.dropFirst().enumerated() {
            let title = part.components(separatedBy: "\n").first ?? ""
            chunks.append(
                HelpChunk(index: offset + 1, title: title, body: sectionMarker.dropFirst() + part))
        }
        return chunks
    }

    // MARK: - Scoring

    private static func queryTerms(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    private static func score(_ chunk: HelpChunk, terms: [String]) -> Int {
        guard !terms.isEmpty else { return 0 }
        let title = chunk.title.lowercased()
        let body = chunk.body.lowercased()
        var total = 0
        for term in terms {
            // A hit in the section title means the query names this subcommand — worth far
            // more than the same word appearing somewhere in its prose.
            if title.contains(term) { total += 10 }
            if body.contains(term) { total += 1 }
        }
        return total
    }

    // MARK: - Truncation

    /// Cuts at the last newline before `limit` so a flag, usage line, or sentence is never
    /// left half-written. Falls back to a hard cut only when there is no newline to use.
    private static func truncateAtLineBoundary(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let lastBreak = head.lastIndex(of: "\n"), head.distance(from: head.startIndex, to: lastBreak) > limit / 2 {
            return String(head[head.startIndex..<lastBreak])
        }
        return head
    }
}

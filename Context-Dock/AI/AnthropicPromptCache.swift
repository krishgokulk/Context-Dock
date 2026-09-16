import Foundation
import OSLog

/// Anthropic prompt caching for the scoped-chat and tool-loop request bodies.
///
/// Caching is a **prefix match** over the rendered request: `tools` → `system` →
/// `messages`. A `cache_control` breakpoint on the last `system` block therefore caches
/// the tool definitions and the system prompt together, and a breakpoint on the last
/// block of the newest message extends the cached span over the conversation so far.
/// Cache reads bill at ~0.1× input; a write costs ~1.25× (5-minute TTL), so two
/// requests sharing a prefix already come out ahead — and a tool loop makes 2–16 of
/// them against the same system prompt and tool set.
///
/// Two constraints shape the helpers below:
/// * Max **4** breakpoints per request — that is why the marker is applied to a *copy*
///   of the body at send time and never stored back into the running `messages` array.
///   Persisting one marker per iteration would blow the limit mid-loop.
/// * The minimum cacheable prefix is model-dependent (512–4096 tokens). Below it the
///   request simply doesn't cache — no error, no extra charge — so marking
///   unconditionally is safe.
enum AnthropicPromptCache {
    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "AnthropicCache")

    /// The `system` field as a cacheable block array. Returns `nil` for an empty prompt
    /// so the caller can omit the field rather than send an empty breakpoint.
    static func systemBlocks(_ prompt: String) -> [[String: Any]]? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return [
            [
                "type": "text",
                "text": prompt,
                "cache_control": ["type": "ephemeral"],
            ]
        ]
    }

    /// Copies `messages` with a cache breakpoint on the last content block of the last
    /// message, so the next request reuses the whole conversation prefix instead of
    /// re-reading it at full price. String content is promoted to a text block —
    /// `cache_control` lives on blocks, not on the bare string form.
    ///
    /// The result is for the request body only. Feeding it back into the stored history
    /// would accumulate one breakpoint per turn and exceed the 4-breakpoint limit.
    static func markingLastBlock(_ messages: [[String: Any]]) -> [[String: Any]] {
        guard var last = messages.last else { return messages }

        if let text = last["content"] as? String {
            last["content"] = [
                [
                    "type": "text",
                    "text": text,
                    "cache_control": ["type": "ephemeral"],
                ]
            ]
        } else if var blocks = last["content"] as? [[String: Any]], !blocks.isEmpty {
            blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
            last["content"] = blocks
        } else {
            return messages
        }

        var marked = messages
        marked[marked.count - 1] = last
        return marked
    }

    /// Reports what the cache actually did. The docs are blunt about this: a
    /// `cache_read_input_tokens` of zero across requests that share a prefix means a
    /// silent invalidator is at work — a timestamp or per-request id inside the system
    /// prompt, a reordered tool array, a model switch. Without this line that failure is
    /// invisible; the requests still succeed, they just cost full price every time.
    static func logUsage(_ usage: AnthropicUsage?, label: String) {
        guard let usage else { return }
        log.debug(
            """
            \(label, privacy: .public): uncached=\(usage.input_tokens ?? 0, privacy: .public) \
            cacheWrite=\(usage.cache_creation_input_tokens ?? 0, privacy: .public) \
            cacheRead=\(usage.cache_read_input_tokens ?? 0, privacy: .public)
            """
        )
    }
}

/// Token accounting from an Anthropic response. `input_tokens` is the **uncached
/// remainder only** — total prompt size is the sum of all three fields.
struct AnthropicUsage: Codable {
    let input_tokens: Int?
    let output_tokens: Int?
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?
}

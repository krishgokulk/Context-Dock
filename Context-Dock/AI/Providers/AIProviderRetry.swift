// AIProviderRetry.swift
// Context-Dock
//
// When a provider says "not now", wait and ask again.
//
// Every provider call in DoraX threw on the first non-2xx. A 429 from Anthropic during a
// burst, a 503 while OpenAI shifts capacity, a dropped connection on hotel wifi — each of
// those ended a turn with "Provider HTTP 429", after the user had already watched the
// spinner and after the tool loop had already done real work it then threw away. All three
// are the provider asking for a pause, not a refusal.
//
// The rate-limit headers were already being read and filed in AIProviderUsageStore; nothing
// acted on them. This is the part that acts on them.

import Foundation

enum AIProviderRetry {

    /// Total attempts, including the first. Three is enough to ride out a burst limit
    /// without leaving a user staring at a window for a minute — past that, the honest
    /// answer is that the provider is unavailable.
    static let maxAttempts = 3

    /// How long to wait before retrying a failed HTTP status, or nil when the status is
    /// the provider's final answer and retrying would only spend the user's quota twice.
    ///
    /// 4xx means the request is wrong and will be wrong again — except 429, which means the
    /// request is fine and the timing is not. 5xx is the provider's own fault and is worth
    /// one more ask.
    static func delay(
        forStatus status: Int,
        headers: [AnyHashable: Any],
        attempt: Int
    ) -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        switch status {
        case 429:
            // The provider usually says exactly how long to wait. Prefer being told over
            // guessing, but never sit longer than a person will wait for a chat reply.
            return min(retryAfter(headers) ?? backoff(attempt: attempt), 30)
        case 500, 502, 503, 504, 529:
            return backoff(attempt: attempt)
        default:
            return nil
        }
    }

    /// How long to wait before retrying a transport failure, or nil when the failure is not
    /// the kind that fixes itself. A cancelled request is the user's decision and must never
    /// be retried behind their back.
    static func delay(forTransport error: Error, attempt: Int) -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        guard let urlError = error as? URLError else { return nil }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
            .dnsLookupFailed, .notConnectedToInternet, .cannotFindHost:
            return backoff(attempt: attempt)
        default:
            return nil
        }
    }

    /// 1s, 2s, 4s, with up to 250 ms of jitter so several chats retrying at once do not
    /// arrive back at the provider in lockstep.
    static func backoff(attempt: Int) -> TimeInterval {
        let base = pow(2.0, Double(max(0, attempt - 1)))
        return base + Double.random(in: 0...0.25)
    }

    /// `Retry-After`, in either of the two forms the HTTP spec allows: a number of seconds,
    /// or an absolute date. Also reads the providers' own reset headers, which several of
    /// them send instead.
    static func retryAfter(_ headers: [AnyHashable: Any]) -> TimeInterval? {
        func value(_ name: String) -> String? {
            for (key, value) in headers
            where (key as? String)?.caseInsensitiveCompare(name) == .orderedSame {
                return value as? String
            }
            return nil
        }

        if let raw = value("retry-after") {
            if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) {
                return max(0, seconds)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: raw) {
                return max(0, date.timeIntervalSinceNow)
            }
        }
        // Anthropic and OpenAI both publish a reset instant for the bucket that was hit.
        for name in [
            "anthropic-ratelimit-requests-reset", "anthropic-ratelimit-tokens-reset",
            "x-ratelimit-reset-requests", "x-ratelimit-reset-tokens",
        ] {
            guard let raw = value(name) else { continue }
            if let date = ISO8601DateFormatter().date(from: raw) {
                return max(0, date.timeIntervalSinceNow)
            }
            // OpenAI writes these as durations: "6m0s", "1.5s", "20ms".
            if let seconds = duration(raw) { return seconds }
        }
        return nil
    }

    /// "6m0s" / "1.5s" / "20ms" → seconds.
    private static func duration(_ raw: String) -> TimeInterval? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty, text.rangeOfCharacter(from: .decimalDigits) != nil else {
            return nil
        }
        var total: TimeInterval = 0
        var number = ""
        var unit = ""
        var matched = false

        func flush() {
            guard let magnitude = Double(number), !unit.isEmpty else { return }
            switch unit {
            case "ms": total += magnitude / 1000
            case "s": total += magnitude
            case "m": total += magnitude * 60
            case "h": total += magnitude * 3600
            default: return
            }
            matched = true
        }

        for character in text {
            if character.isNumber || character == "." {
                if !unit.isEmpty {
                    flush()
                    number = ""
                    unit = ""
                }
                number.append(character)
            } else {
                unit.append(character)
            }
        }
        flush()
        return matched ? total : nil
    }

    /// Sleeps for `delay`, honouring cancellation. Returns false when the wait was
    /// cancelled, so the caller stops rather than retrying work nobody is waiting for.
    static func wait(_ delay: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            return true
        } catch {
            return false
        }
    }
}

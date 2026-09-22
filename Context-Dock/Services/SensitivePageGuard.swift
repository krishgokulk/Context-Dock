// SensitivePageGuard.swift
// Context-Dock
//
// Pages DoraX does not read, and never drives.
//
// While reading a page was passive this mattered little. The moment a chat can navigate, click and
// evaluate JavaScript, it matters completely: the page in front of somebody might be their bank,
// their password manager, or a one-time sign-in link whose URL *is* the credential. A model asked
// to "check this page" should not be the thing that decides whether that is alright.
//
// The rule is a refusal, not a warning, and it names the reason without quoting the page — saying
// "I will not read a page whose URL carries a sign-in token" is useful; printing the token to
// explain is the harm it was avoiding.
//
// Deliberately conservative in one direction only. A false positive costs a refusal the user can
// override by asking about something else; a false negative sends a bank balance, or a password
// field's contents, to a model.

import Foundation

enum SensitivePageGuard {

    enum Reason: Equatable {
        case financialHost(String)
        case credentialHost(String)
        case tokenInURL
        case passwordField
        case userDenied(String)

        var message: String {
            switch self {
            case .financialHost(let host):
                return "\(host) looks like a bank or payment site, so DoraX does not read or "
                    + "drive it."
            case .credentialHost(let host):
                return "\(host) looks like a password or account-security page, so DoraX does "
                    + "not read or drive it."
            case .tokenInURL:
                return "That page's address carries a sign-in token, so DoraX does not read or "
                    + "drive it — the address itself is the credential."
            case .passwordField:
                return "There is a password field on that page, so DoraX does not read it."
            case .userDenied(let host):
                return "You asked DoraX to stay out of \(host)."
            }
        }
    }

    /// Hosts whose business is money moving. Matched on host segments so `chase.com` and
    /// `secure.chase.com` both match while `chasethesun.example` does not.
    private static let financialNeedles: Set<String> = [
        "bank", "banking", "chase", "hsbc", "barclays", "lloyds", "natwest", "santander",
        "monzo", "starling", "revolut", "wise", "paypal", "stripe", "venmo", "wellsfargo",
        "citibank", "capitalone", "amex", "americanexpress", "coinbase", "binance", "kraken",
        "checkout", "billing", "payments",
    ]

    /// Hosts whose business is credentials.
    private static let credentialNeedles: Set<String> = [
        "1password", "lastpass", "bitwarden", "dashlane", "keeper", "authy", "okta", "duo",
        "accounts", "signin", "login", "auth", "idp", "sso", "mfa", "2fa",
    ]

    /// Query or fragment keys that carry something that authenticates.
    private static let tokenKeys: Set<String> = [
        "code", "token", "access_token", "id_token", "refresh_token", "auth", "session",
        "sessionid", "sid", "key", "apikey", "api_key", "password", "pwd", "secret", "otp",
        "magic", "signature", "sig",
    ]

    /// Why this page must not be touched, or nil when it may be.
    ///
    /// - Parameters:
    ///   - hasPasswordField: what the reader saw, when it can tell. The extension knows; an
    ///     AppleScript read does not, and passes false rather than guessing.
    ///   - userDenylist: hosts the user has told DoraX to stay out of.
    static func refusal(
        for urlString: String, hasPasswordField: Bool = false, userDenylist: [String] = []
    ) -> Reason? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else {
            return nil
        }

        for denied in userDenylist {
            let needle = denied.lowercased().trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { continue }
            if host == needle || host.hasSuffix("." + needle) {
                return .userDenied(host)
            }
        }

        if hasPasswordField { return .passwordField }

        if carriesToken(url) { return .tokenInURL }

        let segments = Set(host.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init))
        if let hit = segments.first(where: { financialNeedles.contains($0) }) {
            return .financialHost(host.contains(hit) ? host : hit)
        }
        if let hit = segments.first(where: { credentialNeedles.contains($0) }) {
            return .credentialHost(host.contains(hit) ? host : hit)
        }
        // A path can say it too: /login, /checkout, /reset-password.
        let path = url.path.lowercased()
        for needle in ["/login", "/signin", "/checkout", "/payment", "/reset-password", "/oauth"]
        where path.hasPrefix(needle) || path.contains(needle + "/") {
            return needle.contains("check") || needle.contains("pay")
                ? .financialHost(host) : .credentialHost(host)
        }
        return nil
    }

    static func allows(
        _ urlString: String, hasPasswordField: Bool = false, userDenylist: [String] = []
    ) -> Bool {
        refusal(for: urlString, hasPasswordField: hasPasswordField, userDenylist: userDenylist)
            == nil
    }

    private static func carriesToken(_ url: URL) -> Bool {
        var candidates: [String] = []
        if let query = url.query { candidates.append(query) }
        if let fragment = url.fragment { candidates.append(fragment) }
        for blob in candidates {
            for pair in blob.split(separator: "&") {
                let key = pair.split(separator: "=").first.map(String.init)?.lowercased() ?? ""
                guard tokenKeys.contains(key) else { continue }
                let value = pair.split(separator: "=").dropFirst().joined(separator: "=")
                // A short value is a page number or a country code, not a credential. Real
                // tokens are long, and treating `?code=gb` as one would refuse half the web.
                if value.count >= 12 { return true }
            }
        }
        return false
    }
}

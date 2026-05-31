import AppKit
import Foundation

extension LauncherView {
    // MARK: - Instant Calculator
    func evaluateMathExpression(_ expression: String) -> String? {
        let mathPattern = #"^[\d\s\+\-\*\/\(\)\.\^]+$"#
        guard let regex = try? NSRegularExpression(pattern: mathPattern),
              regex.firstMatch(
                in: expression,
                range: NSRange(expression.startIndex..., in: expression)
              ) != nil
        else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bc")
        process.arguments = ["-l"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()

            let bcExpression = "scale=4; \(expression)\n"
            if let data = bcExpression.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.closeFile()

            process.waitUntilExit()

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            if let result = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines),
               !result.isEmpty,
               process.terminationStatus == 0 {
                return result.replacingOccurrences(
                    of: #"\.?0+$"#,
                    with: "",
                    options: .regularExpression
                )
            }
        } catch {
            return nil
        }

        return nil
    }

    // MARK: - Smart Positioning
    func updateResultsPosition() {
        // Results always show below dock. Kept for compatibility with older call sites.
    }

    // MARK: - Browser Search
    func openInDefaultBrowser() {
        guard !searchState.query.isEmpty else { return }

        let query = searchState.query.trimmingCharacters(in: .whitespaces)
        let urlString: String

        if query.contains(".") && !query.contains(" ") {
            urlString = query.hasPrefix("http://") || query.hasPrefix("https://")
                ? query
                : "https://\(query)"
        } else {
            let encodedQuery =
                query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            urlString = "https://www.google.com/search?q=\(encodedQuery)"
        }

        guard let url = URL(string: urlString) else {
            print("❌ Invalid URL: \(urlString)")
            return
        }

        settings.addRecentWebSearch(query)
        NSWorkspace.shared.open(url)
        searchState.query = ""

        print("🌐 Opening in default browser: \(urlString)")
    }

    func getSearchURL(for query: String) -> URL {
        let encodedQuery =
            query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString =
            query.contains(".") && !query.contains(" ")
            ? (query.hasPrefix("http") ? query : "https://\(query)")
            : "https://www.google.com/search?q=\(encodedQuery)"
        return URL(string: urlString) ?? URL(string: "https://www.google.com")!
    }
}

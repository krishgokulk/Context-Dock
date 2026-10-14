import AppKit
import Foundation

extension LauncherView {


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
            #if DEBUG
            print("❌ Invalid URL: \(urlString)")
            #endif
            return
        }

        settings.addRecentWebSearch(query)
        NSWorkspace.shared.open(url)
        searchState.query = ""

        #if DEBUG
        print("🌐 Opening in default browser: \(urlString)")
        #endif
    }

}

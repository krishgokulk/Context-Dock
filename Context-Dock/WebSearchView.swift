import SwiftUI
import WebKit

// MARK: - Web Search View with WebKit
struct WebSearchView: View {
    let query: String
    let userScripts: [String]
    @Binding var isPresented: Bool
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            // Header with close button
            HStack {
                Text("Web Search: \(query)")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 8)
                }

                Button(action: {
                    isPresented = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // WebKit view
            WebView(url: searchURL, userScripts: userScripts, isLoading: $isLoading)
                .frame(height: 500)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.3), radius: 20)
    }

    private var searchURL: URL {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: "https://www.google.com/search?q=\(encoded)")!
    }
}

// MARK: - WebKit Wrapper
struct WebView: NSViewRepresentable {
    let url: URL
    let userScripts: [String]
    @Binding var isLoading: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()

        // Add user scripts
        for script in userScripts {
            let userScript = WKUserScript(
                source: script,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
            userContentController.addUserScript(userScript)
        }

        config.userContentController = userContentController

        // Enable JavaScript
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.preferences.javaScriptEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Guard against the re-render loop: SwiftUI calls updateNSView on EVERY state
        // change (including isLoading toggling). Using webView.url causes false-positives
        // because webView.url follows redirects. Track what we actually initiated to load.
        if context.coordinator.lastRequestedURL != url {
            context.coordinator.lastRequestedURL = url
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        /// The URL we last asked the webView to load — used to prevent re-render loops.
        var lastRequestedURL: URL? = nil

        init(isLoading: Binding<Bool>) {
            _isLoading = isLoading
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow all navigation
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.isLoading = false
            }
            print("❌ WebView failed to load: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.isLoading = false
            }
            print("❌ WebView provisional navigation failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Web Extension Model
struct WebExtension: Identifiable, Codable {
    let id: UUID
    var name: String
    var script: String
    var enabled: Bool
    var urlPattern: String // Regex or glob pattern for which URLs to inject into

    init(id: UUID = UUID(), name: String, script: String, enabled: Bool = true, urlPattern: String = ".*") {
        self.id = id
        self.name = name
        self.script = script
        self.enabled = enabled
        self.urlPattern = urlPattern
    }
}

import SwiftUI
import WebKit
import AppKit

// MARK: - Web Search Window Manager
class WebSearchWindowManager: NSObject {
    static let shared = WebSearchWindowManager()

    private var webSearchWindow: NSWindow?

    func showWebSearch(query: String, userScripts: [String]) {
        // Close existing window if any
        closeWebSearch()

        // Create window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.center()
        window.title = "Web Search: \(query)"
        window.isReleasedWhenClosed = false
        window.level = .floating

        // Apply modern macOS glass/vibrancy effect
        let opacity = AppSettings.shared.webSearchWindowOpacity
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = CGFloat(opacity)

        // Enable window blur and vibrancy (glass effect)
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)

        // Create the web view controller
        let webViewController = WebSearchWindowController(query: query, userScripts: userScripts)
        window.contentViewController = webViewController

        // Store reference
        webSearchWindow = window

        // Show window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWebSearch() {
        webSearchWindow?.close()
        webSearchWindow = nil
    }
}

// MARK: - Web Search Window Controller
class WebSearchWindowController: NSViewController, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private let query: String
    private let userScripts: [String]
    private var progressIndicator: NSProgressIndicator!
    private var urlTextField: NSTextField!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!

    init(query: String, userScripts: [String]) {
        self.query = query
        self.userScripts = userScripts
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // Create visual effect view for glass/vibrancy effect
        let visualEffectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        visualEffectView.material = .hudWindow // Modern glass material
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        view = visualEffectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupToolbar()
        setupWebView()
        loadInitialURL()
    }

    private func setupToolbar() {
        // Toolbar container at BOTTOM with modern dock-style vibrancy
        let toolbarHeight: CGFloat = 52
        let toolbarEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: view.bounds.width, height: toolbarHeight))
        toolbarEffect.material = .hudWindow
        toolbarEffect.blendingMode = .behindWindow
        toolbarEffect.state = .active
        toolbarEffect.autoresizingMask = [.width, .maxYMargin]
        toolbarEffect.wantsLayer = true
        toolbarEffect.layer?.cornerRadius = 0
        let toolbar = toolbarEffect

        // Center the controls in a horizontal layout
        let buttonSize: CGFloat = 32
        let spacing: CGFloat = 8
        let urlFieldWidth: CGFloat = 500
        let totalWidth = buttonSize * 3 + spacing * 2 + urlFieldWidth + spacing * 3
        let startX = (view.bounds.width - totalWidth) / 2
        let verticalCenter = (toolbarHeight - buttonSize) / 2

        // Back button
        backButton = NSButton(frame: NSRect(x: startX, y: verticalCenter, width: buttonSize, height: buttonSize))
        backButton.bezelStyle = .texturedRounded
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.isEnabled = false
        backButton.isBordered = true
        toolbar.addSubview(backButton)

        // Forward button
        forwardButton = NSButton(frame: NSRect(x: startX + buttonSize + spacing, y: verticalCenter, width: buttonSize, height: buttonSize))
        forwardButton.bezelStyle = .texturedRounded
        forwardButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        forwardButton.isEnabled = false
        forwardButton.isBordered = true
        toolbar.addSubview(forwardButton)

        // Reload button
        reloadButton = NSButton(frame: NSRect(x: startX + (buttonSize + spacing) * 2, y: verticalCenter, width: buttonSize, height: buttonSize))
        reloadButton.bezelStyle = .texturedRounded
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
        reloadButton.target = self
        reloadButton.action = #selector(reload)
        reloadButton.isBordered = true
        toolbar.addSubview(reloadButton)

        // URL text field with rounded modern style
        let urlFieldX = startX + (buttonSize + spacing) * 3
        urlTextField = NSTextField(frame: NSRect(x: urlFieldX, y: verticalCenter, width: urlFieldWidth, height: buttonSize))
        urlTextField.placeholderString = "Search or enter URL..."
        urlTextField.isEditable = true
        urlTextField.isBezeled = true
        urlTextField.bezelStyle = .roundedBezel
        urlTextField.target = self
        urlTextField.action = #selector(loadURL)
        urlTextField.font = NSFont.systemFont(ofSize: 13)
        urlTextField.wantsLayer = true
        urlTextField.layer?.cornerRadius = 8
        toolbar.addSubview(urlTextField)

        // Progress indicator
        progressIndicator = NSProgressIndicator(frame: NSRect(x: urlFieldX + urlFieldWidth - 24, y: verticalCenter + 8, width: 16, height: 16))
        progressIndicator.style = .spinning
        progressIndicator.isHidden = true
        toolbar.addSubview(progressIndicator)

        view.addSubview(toolbar)
    }

    private func setupWebView() {
        // Configure WebView
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
        config.preferences.javaScriptEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Create WebView - positioned ABOVE the bottom toolbar
        let toolbarHeight: CGFloat = 52
        let webViewFrame = NSRect(x: 0, y: toolbarHeight, width: view.bounds.width, height: view.bounds.height - toolbarHeight)
        webView = WKWebView(frame: webViewFrame, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.autoresizingMask = [.width, .height]

        // Make WebView background transparent to show window transparency
        webView.setValue(false, forKey: "drawsBackground")

        view.addSubview(webView)
    }

    private func loadInitialURL() {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
            let request = URLRequest(url: url)
            webView.load(request)
            urlTextField.stringValue = url.absoluteString
        }
    }

    @objc private func goBack() {
        webView.goBack()
    }

    @objc private func goForward() {
        webView.goForward()
    }

    @objc private func reload() {
        webView.reload()
    }

    @objc private func loadURL() {
        let text = urlTextField.stringValue.trimmingCharacters(in: .whitespaces)

        if text.isEmpty {
            return
        }

        // Check if it's a URL
        if let url = URL(string: text), url.scheme != nil {
            let request = URLRequest(url: url)
            webView.load(request)
        } else if text.contains(".") && !text.contains(" ") {
            // Try adding https://
            if let url = URL(string: "https://\(text)") {
                let request = URLRequest(url: url)
                webView.load(request)
            }
        } else {
            // Search on Google
            let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
                let request = URLRequest(url: url)
                webView.load(request)
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true

        // Update URL field
        if let url = webView.url {
            urlTextField.stringValue = url.absoluteString
        }

        // Update navigation buttons
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        print("❌ WebView navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        print("❌ WebView provisional navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Open links that request new windows in the same window
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

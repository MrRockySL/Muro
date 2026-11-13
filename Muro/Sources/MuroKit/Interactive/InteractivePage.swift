import AppKit
import WebKit

/// One interactive wallpaper's page, in a web view (issue #59).
///
/// The same object draws the wallpaper on the desktop and in the gallery's
/// preview. It owns the web view, puts `InteractiveBridge` into the page, and
/// is the only place that talks to it.
///
/// The page is shut in. It is given its own folder and nothing else on the
/// disk, every request to the internet is blocked before it leaves, it keeps
/// nothing between runs, it cannot open a window, and it cannot ask for the
/// camera or the microphone. A page somebody downloaded and imported runs
/// their code on this Mac, so what that code can reach is kept this small.
public final class InteractivePage: NSObject, WKNavigationDelegate, WKUIDelegate {
    public let view: WKWebView
    /// The page asked for the Mac's sound. Told once, on the main queue.
    public var onWantsAudio: (() -> Void)?
    /// The page has loaded and drawn. Told once, on the main queue.
    public var onReady: (() -> Void)?
    public private(set) var wantsAudio = false

    private let index: URL
    private let folder: URL
    private var paused = false
    private var loaded = false
    private var readyTold = false
    private var closed = false
    private var lastMouse = ""
    private var silent = true
    private let messages = MessageRelay()

    /// A web view that never takes the pointer. On the desktop the window
    /// already lets clicks through; in the gallery this is what keeps the
    /// page from swallowing a click meant for the bar drawn over it.
    private final class PageView: WKWebView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
        override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) { menu.removeAllItems() }
    }

    /// The content controller keeps whatever handles its messages alive, so
    /// handing it the page itself would keep page and web view alive forever.
    private final class MessageRelay: NSObject, WKScriptMessageHandler {
        weak var page: InteractivePage?
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            page?.received(message.body)
        }
    }

    public init(index: URL, frame: CGRect) {
        self.index = index
        folder = index.deletingLastPathComponent()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: InteractiveBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        view = PageView(frame: frame, configuration: configuration)
        super.init()

        messages.page = self
        configuration.userContentController.add(messages, name: InteractiveBridge.handlerName)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        view.autoresizingMask = [.width, .height]
        // Black until the page has drawn, never the web view's white.
        view.underPageBackgroundColor = .black
        if view.responds(to: Selector(("setDrawsBackground:"))) {
            view.setValue(false, forKey: "drawsBackground")
        }
    }

    /// Loads the page, once the rules that keep it off the internet are in.
    public func load() {
        Self.networkRules { [weak self] rules in
            guard let self, !self.closed else { return }
            if let rules { self.view.configuration.userContentController.add(rules) }
            self.view.loadFileURL(self.index, allowingReadAccessTo: self.folder)
        }
    }

    /// Lets go of the page. The web view stops and its process goes.
    public func close() {
        guard !closed else { return }
        closed = true
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(
            forName: InteractiveBridge.handlerName
        )
        view.removeFromSuperview()
    }

    // MARK: - What the page is told

    public func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        run("window.muro&&muro.__pause(\(paused))")
    }

    /// Where the pointer is on this page, 0 to 1 from the top left, and
    /// whether the page should answer it: on the desktop, only while it is
    /// on this display and not over an app window.
    public func mouse(x: Double, y: Double, inside: Bool) {
        guard !paused else { return }
        let detail = String(format: "%.4f,%.4f,%@", x, y, inside ? "true" : "false")
        guard detail != lastMouse else { return }
        lastMouse = detail
        run("window.muro&&muro.__mouse(\(detail))")
    }

    public func click(x: Double, y: Double) {
        guard !paused else { return }
        run(String(format: "window.muro&&muro.__click(%.4f,%.4f)", x, y))
    }

    /// What the Mac is playing. Silence is told once and then not again, so a
    /// quiet Mac sends the page nothing.
    public func audio(_ bands: [Float]) {
        guard !paused, wantsAudio else { return }
        let quiet = !bands.contains { $0 > 0.001 }
        if quiet && silent { return }
        silent = quiet
        let list = bands.map { $0 < 0.001 ? "0" : String(format: "%.3f", $0) }.joined(separator: ",")
        run("window.muro&&muro.__audio([\(list)])")
    }

    private func run(_ script: String) {
        guard loaded, !closed else { return }
        view.evaluateJavaScript(script, completionHandler: nil)
    }

    private func received(_ body: Any) {
        guard let message = body as? [String: Any], message["type"] as? String == "audio",
              !wantsAudio
        else { return }
        wantsAudio = true
        onWantsAudio?()
    }

    // MARK: - Shut in

    /// Blocks every request that would leave the Mac. Compiled once and kept
    /// by WebKit; a page loads only after it has them, or has been refused
    /// them, in which case the navigation rules below still hold the page to
    /// its own folder.
    private static func networkRules(_ done: @escaping (WKContentRuleList?) -> Void) {
        let name = "muro-interactive-offline-1"
        let store = WKContentRuleListStore.default()
        store?.lookUpContentRuleList(forIdentifier: name) { found, _ in
            if let found {
                DispatchQueue.main.async { done(found) }
                return
            }
            let block = ["^https?://", "^wss?://", "^ftp://"].map {
                #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"#
            }.joined(separator: ",")
            store?.compileContentRuleList(forIdentifier: name, encodedContentRuleList: "[\(block)]") { made, _ in
                DispatchQueue.main.async { done(made) }
            }
        }
        if store == nil { done(nil) }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" {
            return decisionHandler(.allow)
        }
        let inside = url.isFileURL
            && url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path)
        decisionHandler(inside ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if paused { view.evaluateJavaScript("window.muro&&muro.__pause(true)", completionHandler: nil) }
        // The first frames are drawn a moment after the page says it is done.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.tellReady() }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tellReady()
    }

    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        tellReady()
    }

    /// A page whose process died is loaded again, once it can be seen.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !closed else { return }
        loaded = false
        lastMouse = ""
        silent = true
        wantsAudio = false
        webView.loadFileURL(index, allowingReadAccessTo: folder)
    }

    private func tellReady() {
        guard !readyTold, !closed else { return }
        readyTold = true
        onReady?()
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }

    // A page's alert, confirm or prompt has nobody to answer it.
    public func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    public func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(false)
    }

    public func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        completionHandler(nil)
    }
}

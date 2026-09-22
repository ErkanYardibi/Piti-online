import SwiftUI
import WebKit
import SafariServices

struct PiTiWebView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebContainerViewController { WebContainerViewController() }
    func updateUIViewController(_ controller: WebContainerViewController, context: Context) {}
}

// WKUserContentController retains its handler, so use a weak proxy.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(controller, didReceive: message)
    }
}

final class WebContainerViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let status = UILabel()
    private let retry = UIButton(type: .system)
    private lazy var webView: WKWebView = makeWebView()
    private var progressObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var pageReady = false
    private var routeInFlight = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.numberOfLines = 0
        status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .body)
        status.adjustsFontForContentSizeCategory = true
        retry.setTitle("Tekrar Dene", for: .normal)
        retry.addTarget(self, action: #selector(loadStartPage), for: .touchUpInside)
        [webView, progress, status, retry].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            progress.topAnchor.constraint(equalTo: webView.topAnchor),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            retry.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 20),
            retry.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            self?.progress.progress = Float(webView.estimatedProgress)
            self?.progress.isHidden = webView.estimatedProgress >= 1
        }
        observers.append(NotificationCenter.default.addObserver(forName: .pitiNativeChanged, object: nil, queue: .main) { [weak self] _ in self?.sendNativeState() })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in PushNotificationManager.shared.refresh() }
        })
        PushNotificationManager.shared.refresh()
        loadStartPage()
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.ignoresViewportScaleLimits = false
        // Apply only inside the native app, on every main-frame page load.
        let fixedViewport = WKUserScript(source: """
        (() => {
            let viewport = document.querySelector('meta[name="viewport"]');
            if (!viewport) {
                viewport = document.createElement('meta');
                viewport.name = 'viewport';
                document.head.appendChild(viewport);
            }
            const settings = (viewport.content || 'width=device-width').split(',')
                .filter(value => !/^(initial-scale|minimum-scale|maximum-scale|user-scalable)\\s*=/i.test(value.trim()));
            viewport.content = settings.concat(['initial-scale=1', 'minimum-scale=1',
                'maximum-scale=1', 'user-scalable=no']).join(',');
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(fixedViewport)
        config.userContentController.add(WeakScriptHandler(self), name: "pitiNative")
        config.allowsInlineMediaPlayback = true
        config.applicationNameForUserAgent = "PiTi-iOS/1.0"
        config.websiteDataStore = .default()
        let result = WKWebView(frame: .zero, configuration: config)
        result.navigationDelegate = self
        result.uiDelegate = self
        result.allowsBackForwardNavigationGestures = true
        result.scrollView.keyboardDismissMode = .interactive
        result.scrollView.pinchGestureRecognizer?.isEnabled = false
        // No pull-to-refresh: it could discard an unsaved form.
        return result
    }
    @objc private func loadStartPage() {
        pageReady = false
        guard let url = AppConfiguration.baseURL else {
            showError("Test ortamı henüz yapılandırılmadı. Güvenlik için canlı PiTi’ye bağlanılmadı.")
            return
        }
        status.isHidden = true; retry.isHidden = true; webView.isHidden = false
        if AppConfiguration.environment != "production" {
            // Staging shares the approved DEMO project; production remains blocked.
            let rules = #"""
            [{"trigger":{"url-filter":"^https://objwhegswugyeibcnjfr\\.supabase\\.co/"},"action":{"type":"block"}}]
            """#
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "piti-staging-isolation", encodedContentRuleList: rules) { [weak self] list, error in
                guard let self else { return }
                guard error == nil, let list else { self.showError("Test ortamı güvenlik kuralları yüklenemedi."); return }
                self.webView.configuration.userContentController.add(list)
                self.webView.load(URLRequest(url: url))
            }
        } else { webView.load(URLRequest(url: url)) }
    }
    private func showError(_ message: String = "PiTi’ye ulaşılamıyor. İnternet bağlantını kontrol edip tekrar dene.") {
        pageReady = false; webView.isHidden = true; progress.isHidden = true
        status.text = message; status.isHidden = false; retry.isHidden = false
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { pageReady = false }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { sendNativeState() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showError() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showError() }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { showError() }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if AppConfiguration.isTrusted(url), action.targetFrame?.isMainFrame == true { decisionHandler(.allow); return }
        if action.navigationType == .linkActivated, ["https", "http", "tel", "mailto"].contains(url.scheme ?? "") {
            if AppConfiguration.isTrusted(url) { webView.load(URLRequest(url: url)) }
            else { openExternal(url) }
        }
        decisionHandler(.cancel)
    }
    private func openExternal(_ url: URL) {
        if ["https", "http"].contains(url.scheme ?? "") {
            present(SFSafariViewController(url: url), animated: true)
        } else { UIApplication.shared.open(url) }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "pitiNative", message.frameInfo.isMainFrame,
              AppConfiguration.isTrusted(message.frameInfo.request.url), AppConfiguration.isTrusted(webView.url),
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "ready": pageReady = true; sendNativeState()
        case "requestPushPermission": PushNotificationManager.shared.requestAuthorization()
        case "notificationSettings":
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        default: break
        }
    }
    private func sendNativeState() {
        guard pageReady, AppConfiguration.isTrusted(webView.url) else { return }
        let push = PushNotificationManager.shared
        let state: [String: String] = ["token": push.currentToken ?? "", "permission": push.permission,
            "environment": AppConfiguration.apnsEnvironment, "topic": Bundle.main.bundleIdentifier ?? "",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""]
        webView.callAsyncJavaScript("window.dispatchEvent(new CustomEvent('piti-native-push-token',{detail:state}));", arguments: ["state": state], in: nil, in: .page, completionHandler: nil)
        guard !routeInFlight, let route = push.pendingRoute else { return }
        routeInFlight = true
        webView.callAsyncJavaScript("return window.pitiNativeOpenRoute ? await window.pitiNativeOpenRoute(route) : false;", arguments: ["route": route], in: nil, in: .page) { [weak self] result in
            self?.routeInFlight = false
            if case .success(let consumed) = result, consumed as? Bool == true { push.clearRoute(ifMatching: route) }
        }
    }
}

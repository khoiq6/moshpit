import SwiftUI
import WebKit

/// A separate string table keeps the upstream catalog generator intact.
enum WindowsWords {
    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "Windows")
    }
}

/// Only an explicitly chosen HTTPS gateway is allowed. The app never puts
/// Windows passwords or Guacamole tokens in URLs or its own preferences.
enum WindowsGatewayAddress {
    static func parse(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: trimmed), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil,
              c.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return c.url
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == "https" && b.scheme?.lowercased() == "https" &&
        a.host?.lowercased() == b.host?.lowercased() &&
        (a.port ?? 443) == (b.port ?? 443)
    }
}

@MainActor
final class WindowsGatewayBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var webView: WKWebView?
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    private var origin: URL?

    func open(_ url: URL) {
        close()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.scrollView.bounces = false
        view.allowsBackForwardNavigationGestures = false
        origin = url
        webView = view
        loading = true
        view.load(URLRequest(url: url))
    }

    func retry() {
        guard let view = webView, let origin else { return }
        failed = false
        loading = true
        if view.url != nil { view.reload() } else { view.load(URLRequest(url: origin)) }
    }

    func close() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        origin = nil
        loading = false
        failed = false
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let origin, let target = action.request.url,
              WindowsGatewayAddress.sameOrigin(origin, target) else {
            decisionHandler(.cancel)
            return
        }
        // Keep login and desktop in the same isolated WebKit session.
        if action.targetFrame == nil {
            decisionHandler(.cancel)
            webView.load(action.request)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        failed = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        failed = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false
        failed = true
    }

    private func navigationFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loading = false
        failed = true
    }
}

private struct WindowsGatewaySurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Apache Guacamole renders the actual RDP display and sends input events.
/// No frame rate is simulated; the gateway negotiates its graphics pipeline.
struct WindowsDesktopView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = WindowsGatewayBrowser()
    @AppStorage("windows.gateway.address") private var address = ""
    @State private var showHelp = false
    @State private var immersive = false

    var body: some View {
        NavigationStack {
            Group {
                if let webView = browser.webView {
                    ZStack(alignment: .topTrailing) {
                        WindowsGatewaySurface(webView: webView)
                            .ignoresSafeArea(edges: immersive ? .all : [])
                        if browser.loading {
                            ProgressView().padding(10).background(.regularMaterial, in: Capsule()).padding()
                        }
                        if browser.failed {
                            VStack(spacing: 12) {
                                Text(WindowsWords.text("Could not reach the gateway"))
                                Button(WindowsWords.text("Reconnect")) { browser.retry() }
                                    .buttonStyle(.borderedProminent)
                            }
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding()
                        }
                        if immersive {
                            Button {
                                immersive = false
                            } label: {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .padding(12)
                                    .background(.regularMaterial, in: Circle())
                            }
                            .accessibilityLabel(WindowsWords.text("Show controls"))
                            .padding()
                        }
                    }
                } else {
                    Form {
                        Section(WindowsWords.text("Secure RDP gateway")) {
                            TextField("https://rdp.example.com/guacamole/", text: $address)
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button(WindowsWords.text("Connect to Windows")) {
                                if let url = WindowsGatewayAddress.parse(address) {
                                    address = url.absoluteString
                                    browser.open(url)
                                }
                            }
                            .disabled(WindowsGatewayAddress.parse(address) == nil)
                        }
                        Section {
                            Text(WindowsWords.text("Gateway explanation"))
                            Button(WindowsWords.text("Controls and performance")) { showHelp = true }
                        }
                    }
                }
            }
            .navigationTitle("Windows RDP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(immersive ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(WindowsWords.text("Close")) { browser.close(); dismiss() }
                }
                if browser.webView != nil {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                            .accessibilityLabel(WindowsWords.text("Controls and performance"))
                        Button { browser.retry() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel(WindowsWords.text("Reconnect"))
                        Button { immersive = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .accessibilityLabel(WindowsWords.text("Full screen"))
                    }
                }
            }
            .sheet(isPresented: $showHelp) {
                NavigationStack {
                    List {
                        Section(WindowsWords.text("Mouse and touch")) {
                            Text(WindowsWords.text("Input explanation"))
                            Text(WindowsWords.text("Keyboard explanation"))
                        }
                        Section(WindowsWords.text("Performance")) {
                            Text(WindowsWords.text("Performance explanation"))
                        }
                    }
                    .navigationTitle(WindowsWords.text("Controls and performance"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button(WindowsWords.text("Close")) { showHelp = false }
                    } }
                }
            }
        }
        .onDisappear { browser.close() }
    }
}

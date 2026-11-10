import SwiftUI
import WebKit

struct PetModelStage: View {
    let petID: String?
    let refreshID: UUID
    @Binding var title: String
    @EnvironmentObject private var store: MobileAppStore
    @State private var data: Data?
    @State private var error: String?
    @State private var attempt = 0
    var body: some View {
        ZStack {
            if let data { GLBModelView(data: data).id("\(petID ?? "default")-\(refreshID)") }
            else if let error {
                MobileEmpty(symbol: "pawprint", title: "形象暂时没有打开", detail: error) { attempt += 1 }
            } else { ProgressView("正在同步宠物形象…") }
        }.task(id: "\(store.sessionID)-\(petID ?? "default")-\(refreshID)-\(attempt)") {
            data = nil; error = nil; title = "宠物形象"
            do {
                let result = try await store.petModel(petID: petID)
                if !Task.isCancelled { data = result.data; title = result.title }
            } catch {
                if !Task.isCancelled && !store.handleSessionError(error) { self.error = store.friendly(error) }
            }
        }
    }
}

struct GLBModelView: View {
    let data: Data
    var readinessIdentifier = "modelReady"
    @Environment(\.colorScheme) private var colorScheme
    @State private var loaded = false
    @State private var failed = false
    @State private var fullyFramed = false
    @State private var attempt = 0
    var body: some View {
        ZStack {
            GLBWebSurface(data: data, dark: colorScheme == .dark, loaded: $loaded, failed: $failed, fullyFramed: $fullyFramed)
                .id("\(attempt)-\(colorScheme == .dark)")
                .accessibilityLabel("可拖动和缩放的静态宠物模型")
            if loaded {
                Text("形象已就绪").font(.caption).padding(8).background(.ultraThinMaterial, in: Capsule()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(12).accessibilityIdentifier(readinessIdentifier)
                    .accessibilityValue(fullyFramed ? "完整取景" : "局部视图")
                Button("重置视角") { loaded = false; failed = false; fullyFramed = false; attempt += 1 }
                    .font(.caption).buttonStyle(.bordered).padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .accessibilityIdentifier("\(readinessIdentifier)-reset")
            }
            if !loaded && !failed { ProgressView("正在显示模型…").allowsHitTesting(false) }
            if failed {
                MobileEmpty(symbol: "cube", title: "暂时无法显示模型", detail: "请重新打开形象。") {
                    failed = false; loaded = false; attempt += 1
                }
            }
        }
        .onChange(of: colorScheme) { _, _ in loaded = false; failed = false; fullyFramed = false }
    }
}

private struct GLBWebSurface: UIViewRepresentable {
    let data: Data
    let dark: Bool
    @Binding var loaded: Bool
    @Binding var failed: Bool
    @Binding var fullyFramed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(loaded: $loaded, failed: $failed, fullyFramed: $fullyFramed) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(ModelScheme(data: data), forURLScheme: "pawlyviewer")
        config.userContentController.add(context.coordinator, name: "viewer")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "pawlyviewer://viewer/pawly-viewer.html?dark=\(dark ? 1 : 0)")!))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "viewer")
        uiView.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        @Binding var loaded: Bool
        @Binding var failed: Bool
        @Binding var fullyFramed: Bool
        init(loaded: Binding<Bool>, failed: Binding<Bool>, fullyFramed: Binding<Bool>) {
            _loaded = loaded; _failed = failed; _fullyFramed = fullyFramed
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? String else { return }
            print("Pawly GLB viewer: \(value)")
            if value == "ready" { loaded = true }
            if value == "framing|full" { fullyFramed = true }
            if value == "framing|partial" { fullyFramed = false }
            if value.hasPrefix("error") { failed = true }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed = true
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed = true }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == "pawlyviewer" ? .allow : .cancel)
        }
    }
}

/// Serves only bundled viewer files and already-authorized model bytes. No tokens or remote URLs enter JS.
private final class ModelScheme: NSObject, WKURLSchemeHandler {
    private let model: Data
    private let allowed = ["pawly-viewer.html", "pawly-three.module.js", "pawly-GLTFLoader.js",
                           "pawly-OrbitControls.js", "pawly-BufferGeometryUtils.js", "pawly-RoomEnvironment.js"]
    init(data: Data) { model = data }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let filename = url.lastPathComponent
        print("Pawly GLB resource: \(filename)")
        let bytes: Data
        let mime: String
        if filename == "model.glb" {
            bytes = model; mime = "model/gltf-binary"
        } else if allowed.contains(filename),
                  let resource = Bundle.main.url(forResource: (filename as NSString).deletingPathExtension,
                                                 withExtension: (filename as NSString).pathExtension),
                  let value = try? Data(contentsOf: resource) {
            bytes = value
            mime = filename.hasSuffix(".html") ? "text/html" : "application/javascript"
        } else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                      headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*",
                                                     "Cache-Control": "no-store"])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(bytes)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

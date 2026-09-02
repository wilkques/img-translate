import SwiftUI
import WebKit

/// 包 `WKWebView` 給 SwiftUI 用。`WKUserScript` 是掛在 `WKWebViewConfiguration`
/// 上的,同一個 `WKWebView` 實例換頁(換話/翻頁)時會自動在每次 `document end`
/// 重新注入,不用自己在 `WKNavigationDelegate` 手動重跑腳本。
struct MangaWebView: UIViewRepresentable {
    let urlToLoad: URL?
    let coordinator: TranslationRequestCoordinator

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(
            WeakScriptMessageHandler(target: coordinator),
            name: "imgTranslateBridge"
        )
        contentController.addUserScript(
            WKUserScript(source: PageBridge.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let urlToLoad, webView.url != urlToLoad else { return }
        webView.load(URLRequest(url: urlToLoad))
    }
}

import Foundation
import WebKit
import UIKit

/// 第一輪風險驗證用的協調器:只負責「JS 回報偵測到的圖片網址 → 原生端下載」,
/// 刻意不接翻譯 pipeline——要先確認兩件事都成立,才值得投入完整整合:
/// 1. 原生端用 `URLSession` 帶上頁面 cookie + Referer,抓不抓得到圖(很多站
///    靠這個防盜鏈,單純丟網址下載常常拿到 403 或占位圖)
/// 2. JS 端等 lazy-load 換好真實網址才回報的機制有沒有生效
///
/// 這兩點都驗證過(見 `debugList` 實機測試結果)才進到下一輪接翻譯 pipeline。
@MainActor
final class TranslationRequestCoordinator: NSObject, ObservableObject {

    struct ImageProbe: Identifiable {
        enum Status {
            case detected
            case downloading
            case success(byteCount: Int, pixelSize: CGSize)
            case failed(String)
        }
        let id: String
        let url: URL
        var status: Status
    }

    @Published private(set) var probes: [ImageProbe] = []
    @Published private(set) var pageStatus = "尚未載入"

    weak var webView: WKWebView?

    private var indexByURL: [URL: Int] = [:]

    // MARK: - 圖片偵測

    private func handleDetectedImage(elementId: String, url: URL) {
        guard indexByURL[url] == nil else { return }
        let probe = ImageProbe(id: elementId, url: url, status: .detected)
        probes.append(probe)
        indexByURL[url] = probes.count - 1
        Task { await downloadAndProbe(url: url) }
    }

    private func downloadAndProbe(url: URL) async {
        updateStatus(for: url) { $0 = .downloading }
        do {
            var request = URLRequest(url: url)
            if let webView, let pageURL = webView.url {
                request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
            }
            let cookies = await webView?.configuration.websiteDataStore.httpCookieStore.allCookies() ?? []
            for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let session = URLSession(configuration: .ephemeral)
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                updateStatus(for: url) { $0 = .failed("HTTP \(code)") }
                return
            }
            guard let image = UIImage(data: data) else {
                updateStatus(for: url) {
                    $0 = .failed("下載到的內容不是可解碼的圖片(共 \(data.count) bytes)——可能是防盜鏈回傳的替代頁面")
                }
                return
            }
            updateStatus(for: url) { $0 = .success(byteCount: data.count, pixelSize: image.size) }
        } catch {
            updateStatus(for: url) { $0 = .failed(error.localizedDescription) }
        }
    }

    private func updateStatus(for url: URL, _ mutate: (inout ImageProbe.Status) -> Void) {
        guard let index = indexByURL[url], probes.indices.contains(index) else { return }
        mutate(&probes[index].status)
    }

    private func resetForNewPage() {
        probes = []
        indexByURL = [:]
    }
}

// MARK: - WKScriptMessageHandler

extension TranslationRequestCoordinator: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let elementId = body["id"] as? String,
              let urlString = body["src"] as? String,
              let url = URL(string: urlString) else { return }
        Task { @MainActor in
            self.handleDetectedImage(elementId: elementId, url: url)
        }
    }
}

// MARK: - WKNavigationDelegate

extension TranslationRequestCoordinator: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            self.pageStatus = "載入中…"
            self.resetForNewPage()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.pageStatus = "載入完成" }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.pageStatus = "載入失敗:\(error.localizedDescription)" }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        Task { @MainActor in self.pageStatus = "載入失敗:\(error.localizedDescription)" }
    }
}

private extension WKHTTPCookieStore {
    /// `getAllCookies` 是 callback 介面,包成 async 方便在 `Task` 裡直接 await。
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { cookies in continuation.resume(returning: cookies) }
        }
    }
}

/// `WKUserContentController.add(_:name:)` 會強引用傳入的 handler,如果直接把
/// `TranslationRequestCoordinator`(被 SwiftUI `@StateObject` 持有)傳進去,會形成
/// WebView ↔ Coordinator 互相強引用的循環,畫面關掉後兩者都不會被釋放。用一個
/// 只 weak 持有目標的轉接層打斷循環。
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

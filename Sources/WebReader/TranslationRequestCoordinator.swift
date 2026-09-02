import Foundation
import WebKit
import UIKit

/// 收 JS 回報的圖片網址 → 下載 → 跑既有翻譯 pipeline → 疊字回填 DOM。
///
/// 刻意**不修改**`Sources/OCR/*`、`Sources/Translation/*`——那套 pipeline
/// 已經在固定測試圖上裝機驗證過(見 `ContentView.runVisionPagePipeline`),
/// 這裡只是換一個呼叫端(從「畫一次固定測試圖」換成「畫下載回來的網頁圖」),
/// 整頁對位邏輯(相似度比對、門檻、退回逐塊)照抄那份已驗證的邏輯,不是
/// 重新發明——兩處各自獨立一份,不去動 `ContentView` 已經穩定的程式碼。
@MainActor
final class TranslationRequestCoordinator: NSObject, ObservableObject {

    /// 單一文字區塊的除錯明細,樣式照抄 `ContentView` 的除錯清單(Vision 辨識/
    /// VLM 讀到/譯文/來源)——原本閱讀分頁只顯示「疊字 N 個區塊」的成功筆數,
    /// 看不出區塊內容,遇到「兩個不同原文疊出同一句譯文」這種問題完全無法
    /// 定位是配對錯誤還是模型讀錯,補上這份明細才能真的查。
    struct BlockDebug: Identifiable {
        let id = UUID()
        let visionText: String
        let recognizedText: String
        let translatedText: String
        let source: String
    }

    struct ImageProbe: Identifiable {
        enum Status {
            case detected
            case downloading
            case translating
            case translated(blockCount: Int)
            case noTextFound
            case failed(String)
        }
        let id: String
        let url: URL
        var status: Status
        var blocks: [BlockDebug] = []
    }

    @Published private(set) var probes: [ImageProbe] = []
    @Published private(set) var pageStatus = "尚未載入"
    @Published var sourceLanguage = "es"
    @Published var targetLanguage = "zh-Hant-TW"

    weak var webView: WKWebView?
    let vlmEngine: VLMTranslationEngine

    /// 整頁項目與 Vision 區塊的對位接受門檻,跟 `ContentView` 用同一個起手值。
    private static let pageMatchThreshold = 0.3

    private var indexByURL: [URL: Int] = [:]
    private var elementIdByURL: [URL: String] = [:]

    /// VLM 同時只能處理一個推理(跟 `ContentView` 一樣的限制),原生端維護
    /// 一個序列佇列,不能讓多張圖同時搶著呼叫模型。
    private var pendingJobs: [(url: URL, image: UIImage)] = []
    private var isProcessingQueue = false

    init(vlmEngine: VLMTranslationEngine) {
        self.vlmEngine = vlmEngine
    }

    // MARK: - 圖片偵測 → 下載

    private func handleDetectedImage(elementId: String, url: URL) {
        guard indexByURL[url] == nil else { return }
        let probe = ImageProbe(id: elementId, url: url, status: .detected)
        probes.append(probe)
        indexByURL[url] = probes.count - 1
        elementIdByURL[url] = elementId
        Task { await downloadAndEnqueue(url: url) }
    }

    private func downloadAndEnqueue(url: URL) async {
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
            pendingJobs.append((url: url, image: image))
            processQueueIfNeeded()
        } catch {
            updateStatus(for: url) { $0 = .failed(error.localizedDescription) }
        }
    }

    private func updateStatus(for url: URL, _ mutate: (inout ImageProbe.Status) -> Void) {
        guard let index = indexByURL[url], probes.indices.contains(index) else { return }
        mutate(&probes[index].status)
    }

    private func updateBlocks(for url: URL, _ blocks: [BlockDebug]) {
        guard let index = indexByURL[url], probes.indices.contains(index) else { return }
        probes[index].blocks = blocks
    }

    private func resetForNewPage() {
        probes = []
        indexByURL = [:]
        elementIdByURL = [:]
        pendingJobs = []
    }

    // MARK: - 序列化翻譯佇列

    private func processQueueIfNeeded() {
        guard !isProcessingQueue, !pendingJobs.isEmpty else { return }
        isProcessingQueue = true
        let job = pendingJobs.removeFirst()
        Task {
            await runTranslation(url: job.url, image: job.image)
            isProcessingQueue = false
            processQueueIfNeeded()
        }
    }

    private func runTranslation(url: URL, image: UIImage) async {
        guard let elementId = elementIdByURL[url] else { return }
        updateStatus(for: url) { $0 = .translating }

        let page = RegionCropper.normalizedUp(image)
        guard let pageCG = page.cgImage else {
            updateStatus(for: url) { $0 = .failed("圖片沒有 cgImage") }
            return
        }
        let pixelWidth = pageCG.width
        let pixelHeight = pageCG.height

        let recognized: [RecognizedTextBlock]
        do {
            recognized = try await TextRecognizer.recognizeText(
                in: page,
                recognitionLanguages: [Self.visionRecognitionLanguage(for: sourceLanguage), "en-US"]
            )
        } catch {
            updateStatus(for: url) { $0 = .failed("OCR 失敗:\(error.localizedDescription)") }
            return
        }

        let regions = RegionMerger.merge(recognized, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        guard !regions.isEmpty else {
            updateStatus(for: url) { $0 = .noTextFound }
            return
        }

        var fractionalBlocks: [[String: Any]] = []
        var blockDebugs: [BlockDebug] = []
        var usedIndices = Set<Int>()

        if let pageResult = try? await vlmEngine.translatePage(
            pageCG, expectedBlockCount: regions.count, from: sourceLanguage, to: targetLanguage) {
            for item in pageResult.items {
                guard !item.isDegenerate, !item.translated.isEmpty else { continue }
                let foldedOriginal = PageOutputParser.fold(item.original)
                var bestIndex: Int?
                var bestScore = 0.0
                for i in regions.indices where !usedIndices.contains(i) {
                    let score = PageOutputParser.similarity(
                        foldedOriginal, PageOutputParser.fold(regions[i].visionText))
                    if score > bestScore { bestScore = score; bestIndex = i }
                }
                guard let i = bestIndex, bestScore >= Self.pageMatchThreshold else { continue }
                usedIndices.insert(i)
                fractionalBlocks.append(
                    Self.fractionalPayload(
                        pixelRect: regions[i].pixelRect, text: item.translated,
                        pixelWidth: pixelWidth, pixelHeight: pixelHeight))
                blockDebugs.append(BlockDebug(
                    visionText: regions[i].visionText,
                    recognizedText: item.original,
                    translatedText: item.translated,
                    source: "整頁(分數 \(String(format: "%.2f", bestScore)))"))
            }
        }

        // 整頁沒對到的區塊退回逐塊路線,跟 `ContentView.runVisionPagePipeline`
        // 同一套邏輯:寧可多花一次推理,也不要把譯文綁到錯的框。
        //
        // ⚠️ 2026-09-02 裝機實測:連續處理第 3、4 張網頁圖時 OOM 閃退,前兩張
        // (各 7、2 個文字區塊)撐過去了。`VLMTranslationEngine.finishPage()`
        // 的既有註解明講「不要每塊都叫,會逼 MLX 重新配置緩衝區,反而更慢」——
        // 那是針對「一次只處理一張固定測試圖」的情境(`ContentView`)優化的
        // 假設。這裡的使用情境完全不同:一個閱讀 session 要連續處理**不限
        // 張數**的網頁圖,每張圖本身可能又有好幾個區塊要各自呼叫一次逐塊
        // fallback——舊的「每張圖結束才清一次」在這裡等於讓 Metal 快取跨越
        // 好幾次推理持續累積,撐不到清的那一刻就先 OOM。改成每個 fallback
        // 區塊都清一次,用推理速度換穩定性,這是這輪的實驗性修法,如果裝機
        // 證實有效但速度明顯變慢,再考慮折衷(例如每 N 個區塊清一次)。
        for i in regions.indices where !usedIndices.contains(i) {
            let cropRect = RegionCropper.padded(
                regions[i].pixelRect, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            guard let crop = RegionCropper.crop(page, toPixelRect: cropRect) else { continue }
            guard let result = try? await vlmEngine.translateRegion(
                crop, widerContext: pageCG, from: sourceLanguage, to: targetLanguage),
                result.translatedText != VLMTranslationEngine.failureMessage else { continue }
            fractionalBlocks.append(
                Self.fractionalPayload(
                    pixelRect: regions[i].pixelRect, text: result.translatedText,
                    pixelWidth: pixelWidth, pixelHeight: pixelHeight))
            blockDebugs.append(BlockDebug(
                visionText: regions[i].visionText,
                recognizedText: result.recognizedText,
                translatedText: result.translatedText,
                source: "逐塊(整頁沒對到)"))
            vlmEngine.finishPage()
        }
        vlmEngine.finishPage()

        updateBlocks(for: url, blockDebugs)

        guard !fractionalBlocks.isEmpty else {
            updateStatus(for: url) { $0 = .failed("OCR 找到文字但翻譯全部失敗") }
            unloadEngineForNextImage()
            return
        }
        updateStatus(for: url) { $0 = .translated(blockCount: fractionalBlocks.count) }
        await applyOverlay(elementId: elementId, blocks: fractionalBlocks)
        unloadEngineForNextImage()
    }

    /// ⚠️ 2026-09-02:逐塊清 Metal 快取(`finishPage()`)只清得動可回收的快取,
    /// 清不動模型容器本身常駐的記憶體——實測換小模型才真的解決 OOM,但小模型
    /// 翻譯品質明顯打折。改成**每張圖處理完就整個卸載模型**,下一張圖開始
    /// 翻譯時 `ensureLoaded()` 會偵測到 `container` 是 nil 重新載入,強制把
    /// 記憶體歸零到跟剛啟動時一樣的基準,換回用 `Qwen3-VL-4B` 的品質。代價是
    /// 每張圖之間多了重新載入權重+暖機的延遲(權重已經在本機,不用重新下載,
    /// 但讀檔+編譯 Metal pipeline 還是要花時間)——用速度換品質+穩定性,跟
    /// 之前「逐塊清快取」用速度換穩定性是同一個方向,只是這次動的是更重的
    /// 那一層。這是實驗性做法,如果重新載入的延遲拖到不能接受,再考慮拉長
    /// 卸載週期(例如每 2-3 張圖才卸載一次)。
    private func unloadEngineForNextImage() {
        vlmEngine.unload()
    }

    private static func fractionalPayload(
        pixelRect: CGRect, text: String, pixelWidth: Int, pixelHeight: Int
    ) -> [String: Any] {
        [
            "left": Double(pixelRect.minX) / Double(pixelWidth) * 100,
            "top": Double(pixelRect.minY) / Double(pixelHeight) * 100,
            "width": Double(pixelRect.width) / Double(pixelWidth) * 100,
            "height": Double(pixelRect.height) / Double(pixelHeight) * 100,
            "text": text
        ]
    }

    private func applyOverlay(elementId: String, blocks: [[String: Any]]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: blocks),
              let json = String(data: data, encoding: .utf8) else { return }
        let escapedId = elementId.replacingOccurrences(of: "'", with: "\\'")
        let script = "window.imgTranslateApplyOverlay && window.imgTranslateApplyOverlay('\(escapedId)', \(json));"
        _ = try? await webView?.evaluateJavaScript(script)
    }

    /// 依語言代碼組出 Vision 看得懂的 recognitionLanguages 格式(BCP-47),跟
    /// `ContentView.visionRecognitionLanguage` 同一份對照表。
    private static func visionRecognitionLanguage(for code: String) -> String {
        switch code {
        case "es": return "es-ES"
        case "en": return "en-US"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "zh-Hans": return "zh-Hans"
        case "zh-Hant-TW": return "zh-Hant"
        default: return code
        }
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

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

    /// 「整話先翻完再看」模式的狀態——見 `startPreTranslateAll` 的說明。
    /// `preTranslateTotal` 用 `Int?`(不是 0)區分「還不知道有幾張」跟
    /// 「JS 回報總共 0 張候選圖片」,不然 `checkPreTranslateCompletion` 會在
    /// JS 都還沒回應時,就因為「目前 0 張、目標 0 張、佇列是空的」而誤判
    /// 成「已經全部翻完」,瞬間解除遮罩。
    @Published private(set) var isPreTranslating = false
    @Published private(set) var preTranslateTotal: Int?

    /// 2026-09-03:實驗開關——開著時 `runTranslation` 完全跳過整頁/逐塊讀圖
    /// 路線,改成 Vision OCR 文字直接丟 VLM 純文字翻譯(`VLMTranslationEngine.
    /// translateText`)。用來對照「文字路線」跟「讀圖路線」的速度/品質,方便
    /// 同一顆 build 上直接切換比較,不用等兩次 CI。
    @Published var useTextOnlyTranslation = false

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

    /// 2026-09-03:純文字模式(`useTextOnlyTranslation`)用的上下文記憶——
    /// 跨整個閱讀 session(不是只在同一張圖內)累積最近翻過的「原文→譯文」,
    /// 讓模型有機會維持人名/語氣一致性。`resetForNewPage` 換頁會清空(新的
    /// 一話沒理由沿用上一話的上下文)。
    ///
    /// Cyril 要求從 6 拉到 20——沒有圖片 token 的路線,20 行文字對提示長度
    /// 影響還算小,但每次呼叫要多讀的內容變多,裝機驗證要留意速度有沒有
    /// 明顯變慢,以及行數變多會不會讓模型更容易把上下文內容也一起吐出來
    /// (「僅供參考」這句指示原本是針對 6 行測的,行數變多沒重新驗證過)。
    private var recentTextTranslations: [(original: String, translated: String)] = []
    private static let maxContextLines = 20

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

    /// 手動重試——Cyril 要求能直接點選重來,不用重新整個網頁重新捲一次,
    /// 而且不要只在失敗時才給(見 `MangaReaderView.isRetryable`,幾乎所有
    /// 狀態都放行)。重用既有的 `downloadAndEnqueue`(重新下載+排隊翻譯),
    /// 因為 `updateStatus`/`updateBlocks` 都是用 `indexByURL[url]` 找既有的
    /// `ImageProbe` 原地更新,這裡不用另外處理「重複項目」的問題——
    /// `handleDetectedImage` 那個 `indexByURL[url] == nil` 的守門只擋「JS 又
    /// 回報同一張圖」,不擋這個手動重試路徑。
    ///
    /// ⚠️ 沒有防呆擋「正在下載/翻譯中還按重試」——這個由呼叫端(UI)自己
    /// 用 `isRetryable` 過濾掉,這裡沒有重複呼叫防護,如果之後有其他呼叫端
    /// 不經過那層過濾直接呼叫這個函式,同一張圖可能被排進佇列處理兩次。
    func retryTranslation(for url: URL) {
        Task { await downloadAndEnqueue(url: url) }
    }

    /// 2026-09-03:Cyril 確認「追求翻譯品質」——邊捲邊翻(`IntersectionObserver`
    /// 提前偵測)在這個 VLM pipeline 下永遠追不上正常捲動速度(單一序列推理,
    /// 一張圖好幾個區塊,每區塊數秒起跳),體驗比等一次翻完更差。改成這個
    /// 模式:無視目前捲動位置,叫 JS 把頁面上現有的候選圖片全部回報,原生端
    /// 全部翻完之前用 `isPreTranslating` 讓畫面蓋一層進度遮罩擋住閱讀。
    ///
    /// 只找「JS 呼叫當下 DOM 裡已經存在」的圖——如果站方是虛擬捲動(圖片
    /// 節點要捲到夠近才會被插入 DOM),這個模式在使用者開始捲動前根本看
    /// 不到那些圖,`preTranslateTotal` 只會反映當下找得到的張數,不是整個
    /// 章節「應該有」的張數。目前測試站(`olympusxyz.com`)已確認整話圖片
    /// 是伺服器端一次全部算好、直接在初始 HTML 裡,不是虛擬捲動,這個假設
    /// 成立;之後如果換一個用虛擬捲動的站,這個模式要重新評估。
    func startPreTranslateAll() {
        guard !isPreTranslating else { return }
        isPreTranslating = true
        preTranslateTotal = nil
        Task {
            let result = try? await webView?.evaluateJavaScript(
                "window.imgTranslateReportAll && window.imgTranslateReportAll();"
            )
            preTranslateTotal = (result as? NSNumber)?.intValue ?? 0
            checkPreTranslateCompletion()
        }
    }

    /// 使用者不想等,先看已經翻好的部分——只是拿掉畫面上的進度遮罩,已經
    /// 排進佇列的翻譯工作不會被取消,還是會在背景繼續跑完,之後捲到一樣
    /// 會看到疊字(維持既有的「邊捲邊翻」行為當作後備)。
    func skipPreTranslateWait() {
        isPreTranslating = false
    }

    /// 每次任何一張圖的狀態改變都檢查一次——邏輯很單純(掃一次 `probes`),
    /// 章節頂多幾十張圖,不需要另外做增量計數優化。
    private func checkPreTranslateCompletion() {
        guard isPreTranslating, let total = preTranslateTotal, probes.count >= total,
              pendingJobs.isEmpty, !isProcessingQueue else { return }
        guard probes.allSatisfy({ !Self.isSettling($0.status) }) else { return }
        isPreTranslating = false
    }

    private static func isSettling(_ status: ImageProbe.Status) -> Bool {
        switch status {
        case .detected, .downloading, .translating: return true
        case .translated, .noTextFound, .failed: return false
        }
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
        checkPreTranslateCompletion()
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
        isPreTranslating = false
        preTranslateTotal = nil
        recentTextTranslations = []
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

        // ⚠️ 2026-09-02 裝機抓到的 bug:`RegionMerger.merge` 的預設
        // `heightInflate` 是 **1.0(完全不撐高)**,兩行字之間本來就有行距,
        // 不撐高就永遠碰不到、永遠不會合併——實測一個對話框裡的
        // 「NO FUE」/「TAN AGOTADOR」/「COMO PENSABA.」(其實是一整句話拆成
        // 三行)被當成三個獨立區塊分開送去翻譯,模型拿到的是無意義的碎片,
        // 當然翻不出東西(`VLM讀到` 全空、譯文直接把原文吐回來)。
        //
        // 那個 `1.0` 是當初為了修「原生疊字方框互相重疊」才改的,但網頁這條
        // 路線的疊字是用 DOM 畫、吃的是原始 `pixelRect`,那個理由不成立。
        // 這裡明確傳 1.5 覆寫,不動共用的預設值——「引擎測試」分頁(目前隱藏)
        // 的原生疊字路線維持原本行為,不被這次改動波及。
        //
        // 選 1.5 的理由:撐大是以中心點對稱擴張,`k=1.5` 等於上下各多 25% 行高,
        // 足以跨過一般漫畫字體 20-50% 行高的行距。**刻意偏向「寧可多合併」**——
        // 合併過頭最多是一次看到兩個對話框(模型兩句都翻,疊字位置略偏但讀得懂),
        // 合併不足卻會產生完全無法翻譯的碎片,後者明顯更糟。
        let regions = RegionMerger.merge(
            recognized, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            heightInflate: 1.5)
        guard !regions.isEmpty else {
            updateStatus(for: url) { $0 = .noTextFound }
            return
        }

        var fractionalBlocks: [[String: Any]] = []
        var blockDebugs: [BlockDebug] = []

        // ⚠️ 2026-09-03:**實驗性路線**——測試「Vision OCR(已經關掉語言校正,
        // 準確率提升)夠準的話,直接把 OCR 文字丟給 VLM 純文字翻譯,不用繞去
        // 讀裁圖」這個假設。開著這個開關時完全跳過下面的整頁 VLM 讀圖 + 逐塊
        // 讀圖 fallback,改成每個區塊都呼叫 `VLMTranslationEngine.translateText`
        // (見該檔案的說明)。這是為了乾淨對照兩條路線,不要混在一起跑。
        if useTextOnlyTranslation {
            for region in regions {
                guard let translated = try? await vlmEngine.translateText(
                    region.visionText, from: sourceLanguage, to: targetLanguage,
                    context: recentTextTranslations) else {
                    blockDebugs.append(BlockDebug(
                        visionText: region.visionText, recognizedText: region.visionText,
                        translatedText: VLMTranslationEngine.failureMessage, source: "純文字,失敗"))
                    continue
                }
                blockDebugs.append(BlockDebug(
                    visionText: region.visionText, recognizedText: region.visionText,
                    translatedText: translated,
                    source: translated == VLMTranslationEngine.failureMessage ? "純文字,失敗" : "純文字"))
                guard translated != VLMTranslationEngine.failureMessage else { continue }
                // 只有真的翻成功才存進上下文——失敗訊息本身不是有效的譯文,
                // 存進去只會誤導後面的呼叫。
                recentTextTranslations.append((original: region.visionText, translated: translated))
                if recentTextTranslations.count > Self.maxContextLines {
                    recentTextTranslations.removeFirst()
                }
                fractionalBlocks.append(
                    Self.fractionalPayload(
                        pixelRect: region.pixelRect, text: translated,
                        pixelWidth: pixelWidth, pixelHeight: pixelHeight))
            }
            vlmEngine.finishPage()
            updateBlocks(for: url, blockDebugs)
            guard !fractionalBlocks.isEmpty else {
                updateStatus(for: url) { $0 = .failed("OCR 找到文字但翻譯全部失敗") }
                return
            }
            updateStatus(for: url) { $0 = .translated(blockCount: fractionalBlocks.count) }
            await applyOverlay(elementId: elementId, blocks: fractionalBlocks)
            return
        }

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
                crop, widerContext: pageCG, from: sourceLanguage, to: targetLanguage) else {
                vlmEngine.finishPage()
                continue
            }
            // ⚠️ 2026-09-03:原本失敗(`translatedText == failureMessage`)直接
            // `continue`,完全不記錄除錯明細——結果是「OCR 找到文字但翻譯全部
            // 失敗」這種整張圖失敗的狀態,展開明細是空的,看不出模型當下到底
            // 吐了什麼、是不是又是照抄或卡迴圈。改成失敗也記一筆(`來源` 標
            // 「失敗」),只是不疊字、不算進 `fractionalBlocks`。
            //
            // ⚠️ 2026-09-03:曾經在這裡接過 Google 翻譯備援(本機模型失敗時
            // 改送文字去 Google 免費端點翻譯),裝機實測發現這個免費端點會被
            // Google 的濫用防護擋下來(`HTTP 429`),試過加呼叫間隔節流也沒用
            // ——裝置所在網路的 IP 應該已經被標記。Cyril 確認放棄這條備援,
            // 失敗就是失敗,交給使用者用既有的手動重試按鈕自己決定要不要
            // 再試一次。`GoogleTranslateFallback.swift` 已整個移除,不要再
            // 加回來,除非之後真的要換官方付費 API。
            let source = result.translatedText == VLMTranslationEngine.failureMessage
                ? "逐塊,翻譯失敗" : "逐塊(整頁沒對到)"
            blockDebugs.append(BlockDebug(
                visionText: regions[i].visionText,
                recognizedText: result.recognizedText,
                translatedText: result.translatedText,
                source: source))
            vlmEngine.finishPage()
            guard result.translatedText != VLMTranslationEngine.failureMessage else { continue }
            fractionalBlocks.append(
                Self.fractionalPayload(
                    pixelRect: regions[i].pixelRect, text: result.translatedText,
                    pixelWidth: pixelWidth, pixelHeight: pixelHeight))
        }
        vlmEngine.finishPage()

        updateBlocks(for: url, blockDebugs)

        guard !fractionalBlocks.isEmpty else {
            updateStatus(for: url) { $0 = .failed("OCR 找到文字但翻譯全部失敗") }
            return
        }
        updateStatus(for: url) { $0 = .translated(blockCount: fractionalBlocks.count) }
        await applyOverlay(elementId: elementId, blocks: fractionalBlocks)
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

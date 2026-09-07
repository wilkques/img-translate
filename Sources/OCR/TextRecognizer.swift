import Vision
import UIKit

struct RecognizedTextBlock {
    let text: String
    /// Vision 原生格式:正規化座標(0-1),原點左下角
    let normalizedBoundingBox: CGRect
    /// Vision 對這段辨識結果的信心值(0-1),VLM 混合式架構下只當除錯/排序參考用,
    /// 不影響本文字內容是否採用(文字內容一律交給 VLM 判斷)。
    let confidence: Float
    /// 2026-09-04:Vision 第 2、3 名候選字串(不含第一名,第一名就是 `text`)。
    /// 裝機實測發現這個字體的 U/L 形狀容易混淆(`SIGUIENDO` 被讀成
    /// `SIGLIIENDO`),關掉語言校正沒解決這類視覺層級誤讀。Vision 本身在
    /// 算候選字串時對曖昧筆畫會有不同猜測,把第一名以外的候選也留著,交給
    /// 下游(純文字翻譯 prompt)當「這裡可能有其他讀法」的提示,讓語言模型
    /// 自己判斷哪個讀法才是通順的句子——比我們自己刻一套拼字修正邏輯划算。
    let alternates: [String]
}

enum TextRecognizer {
    /// ⚠️ 已知風險(見 PROGRESS/README):Vision 對漫畫手寫感粗體字、狀聲詞的辨識準確度沒把握,
    /// 呼叫端要把這裡回傳的原始辨識文字顯示出來,方便判斷是辨識錯還是翻譯錯。
    static func recognizeText(
        in image: UIImage,
        recognitionLanguages: [String]
    ) async throws -> [RecognizedTextBlock] {
        guard let cgImage = image.cgImage else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let blocks = observations.compactMap { obs -> RecognizedTextBlock? in
                    let candidates = obs.topCandidates(3)
                    guard let best = candidates.first else { return nil }
                    let alternates = candidates.dropFirst().map { $0.string }
                    return RecognizedTextBlock(
                        text: best.string,
                        normalizedBoundingBox: obs.boundingBox,
                        confidence: best.confidence,
                        alternates: alternates)
                }
                continuation.resume(returning: blocks)
            }
            // ⚠️ 2026-09-04:Cyril 對照 Safari 的「即時文字辨識」發現同一段
            // 難字(`NA MUGYEOM`)Safari 讀得出來、我們讀成 `NA MLGYEOM`。
            // 兩邊底層都是 Vision 框架,但我們原本完全沒指定 `revision`,吃
            // 系統預設值——Vision 文字辨識這幾年有明顯升級過準確度的版本,
            // Safari 這種第一方系統功能通常會用最新的。明確指定裝置支援的
            // 最新 revision,純設定改動,不影響任何 prompt/解析邏輯。
            if let latestRevision = VNRecognizeTextRequest.supportedRevisions.max() {
                request.revision = latestRevision
            }
            request.recognitionLevel = .accurate
            // ⚠️ 2026-09-03:原本是 `true`。這個選項的設計目的是把辨識結果修正成
            // 字典裡的真實單字——但漫畫狀聲詞/喊叫聲(`UWA`、`GRRRAAAGH`)本來就
            // 不是真實單字,懷疑這正是先前抓到「¡UWA! 被認成 ¡LIWA!」這類誤讀的
            // 根因(語言校正把不像字典字的辨識結果強行修正成一個看起來像字但其實
            // 錯的結果)。改成 `false`,單獨測試對這類難字的辨識準確度有沒有改善,
            // 同時要確認沒有把 `YA BASTA`/`ERES RUIDOSO` 這類原本讀對的正常對話拖累。
            request.usesLanguageCorrection = false
            request.recognitionLanguages = recognitionLanguages
            // ⚠️ 2026-09-04:指定最新 revision 後 U/L 誤讀(`MUGYEOM` 讀成
            // `MLGYEOM`)依然沒有改善。這是對照 Safari 差異最後一個成本一樣低
            // 的變因:我們原本限定西班牙文+英文,Safari 的即時文字辨識很可能
            // 是自動偵測語言、不限定。`automaticallyDetectsLanguage = true`
            // 讓 Vision 自己判斷語言,不受 `recognitionLanguages` 限制——如果
            // 這樣還是沒改善,代表這是 Vision 框架對這個字體 U/L 筆畫辨識的
            // 真實極限,不用再往「調 Vision 設定」這個方向投入。
            request.automaticallyDetectsLanguage = true
            // 濾掉太小的雜訊框(例如漫畫畫面裡的細小線條被誤判成文字),
            // 混合式架構下每個框都要多跑一次 VLM 推理,少一個雜訊框就少一次呼叫。
            request.minimumTextHeight = 0.01

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// 2026-09-07:裝機抓到根因——長條漫畫網站(webtoon 直式長圖,實測案例
    /// 720x6668)整張圖丟給 Vision 時,`recognizeText` 回傳完全空陣列,連
    /// VisionKit `ImageAnalyzer`(`LiveTextRecognizer`)也讀不到任何一行,
    /// 但畫面上肉眼清楚可見對話框文字。這個專案從一開始驗證的固定測試圖
    /// (`Fixtures/sample-es.jpg`)只有 1145px 高,從沒測過這種極端長寬比的
    /// 輸入——懷疑兩顆框架內部都對輸入圖有隱性的降採樣上限,超長圖被縮得
    /// 太小,文字筆畫在縮圖後低於可辨識的解析度(沒辦法讀到框架原始碼證實
    /// 確切門檻,但這個假設可以直接用「切小塊」繞過,不需要先證實才能修)。
    ///
    /// 修法:超過門檻高度就切成上下有重疊的長條,每條在**原始解析度**
    /// (不整張縮放)跑 `recognizeText`,再把每條的結果換算回整頁的正規化
    /// 座標系。門檻(1600px)刻意抓在跟已驗證過的固定測試圖同一個量級,
    /// 不是精算出來的安全值。重疊(15%)是為了同一個對話框如果跨在切點
    /// 上,至少有一條能完整收進去,不會被攔腰切成兩段各自都讀不完整。
    ///
    /// 一般大小的圖(高度沒超過門檻)直接呼叫 `recognizeText`,行為跟改動前
    /// 完全一樣——這是刻意保留的分岔,已經裝機驗證很多輪的正常案例路徑
    /// 不冒風險。
    static func recognizeTextTiled(
        in image: UIImage,
        recognitionLanguages: [String],
        maxTileHeight: CGFloat = 1600,
        overlapFraction: CGFloat = 0.15
    ) async throws -> [RecognizedTextBlock] {
        guard let cgImage = image.cgImage else { return [] }
        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height

        guard CGFloat(pixelHeight) > maxTileHeight else {
            return try await recognizeText(in: image, recognitionLanguages: recognitionLanguages)
        }

        let overlap = maxTileHeight * overlapFraction
        let stride = maxTileHeight - overlap
        var tileTops: [CGFloat] = []
        var top: CGFloat = 0
        while true {
            tileTops.append(top)
            if top + maxTileHeight >= CGFloat(pixelHeight) { break }
            top += stride
        }

        var merged: [RecognizedTextBlock] = []
        for tileTop in tileTops {
            let tileHeight = min(maxTileHeight, CGFloat(pixelHeight) - tileTop)
            let pixelRect = CGRect(x: 0, y: tileTop, width: CGFloat(pixelWidth), height: tileHeight)
            guard let tileCG = cgImage.cropping(to: pixelRect) else { continue }
            let tileImage = UIImage(cgImage: tileCG, scale: image.scale, orientation: .up)
            let tileBlocks = try await recognizeText(in: tileImage, recognitionLanguages: recognitionLanguages)

            for block in tileBlocks {
                let box = block.normalizedBoundingBox
                // tile 內的正規化 y(原點左下)→ 整頁像素 → 整頁正規化 y,
                // 換算方式跟 `RegionCropper.paddedPixelRect` 同一套邏輯
                // (y 軸翻轉:Vision 由下往上,像素由上往下)。
                let pageTopPx = tileTop + (1 - box.maxY) * tileHeight
                let pageBottomPx = tileTop + (1 - box.minY) * tileHeight
                let newMinY = 1 - (pageBottomPx / CGFloat(pixelHeight))
                let newMaxY = 1 - (pageTopPx / CGFloat(pixelHeight))
                let newBox = CGRect(
                    x: box.minX, y: newMinY,
                    width: box.width, height: newMaxY - newMinY)
                merged.append(RecognizedTextBlock(
                    text: block.text,
                    normalizedBoundingBox: newBox,
                    confidence: block.confidence,
                    alternates: block.alternates))
            }
        }

        return dedupOverlapZone(merged, pixelHeight: pixelHeight)
    }

    /// 重疊區內同一個對話框可能被相鄰兩條各自完整抓到一次,產生內容幾乎
    /// 一樣、位置幾乎一樣的兩筆——不去重的話會被 `RegionMerger` 當成
    /// 「撐大後碰撞的兩個框」直接把文字接在一起(`"X X"` 這種重複內容),
    /// 比對照文字+位置接近程度來去重更省事、也更貼近真正的失敗模式。
    private static func dedupOverlapZone(
        _ blocks: [RecognizedTextBlock], pixelHeight: Int
    ) -> [RecognizedTextBlock] {
        var kept: [RecognizedTextBlock] = []
        for block in blocks {
            let isDuplicate = kept.contains { existing in
                guard existing.text == block.text else { return false }
                let dy = abs(existing.normalizedBoundingBox.midY - block.normalizedBoundingBox.midY)
                    * CGFloat(pixelHeight)
                return dy < 40
            }
            if !isDuplicate {
                kept.append(block)
            }
        }
        return kept
    }
}

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
}

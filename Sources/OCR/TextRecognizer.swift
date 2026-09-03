import Vision
import UIKit

struct RecognizedTextBlock {
    let text: String
    /// Vision 原生格式:正規化座標(0-1),原點左下角
    let normalizedBoundingBox: CGRect
    /// Vision 對這段辨識結果的信心值(0-1),VLM 混合式架構下只當除錯/排序參考用,
    /// 不影響本文字內容是否採用(文字內容一律交給 VLM 判斷)。
    let confidence: Float
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
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return RecognizedTextBlock(
                        text: candidate.string,
                        normalizedBoundingBox: obs.boundingBox,
                        confidence: candidate.confidence)
                }
                continuation.resume(returning: blocks)
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

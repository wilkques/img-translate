import Vision
import UIKit

struct RecognizedTextBlock {
    let text: String
    /// Vision 原生格式:正規化座標(0-1),原點左下角
    let normalizedBoundingBox: CGRect
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
                    return RecognizedTextBlock(text: candidate.string, normalizedBoundingBox: obs.boundingBox)
                }
                continuation.resume(returning: blocks)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = recognitionLanguages

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

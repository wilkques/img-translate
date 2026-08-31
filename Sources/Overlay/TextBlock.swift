import Foundation
import CoreGraphics

struct TextBlock: Identifiable {
    let id = UUID()
    /// Vision 辨識出的原文(合併過同一對話框的多行),只做除錯對照與 fallback 用。
    let visionText: String
    /// VLM 直接讀裁圖辨識出的原文,跟 `visionText` 分開存,方便除錯清單對照兩者差異。
    var recognizedText: String?
    var translatedText: String?
    /// 圖片像素座標,原點左上——裁圖跟疊字統一用這個座標系。
    let pixelRect: CGRect

    // MARK: - 除錯欄位(只餵除錯清單,不影響疊字顯示)

    /// 模型最後一次生成的原始輸出(沒被 `parse()` 整理過的完整內容)。
    var rawOutput: String?
    /// 有沒有走過寬範圍裁圖的重試路線。
    var usedWiderContextRetry: Bool = false
    /// 走過重試時,主要路線(緊裁圖)那次的原始輸出,用來對照兩次生成差在哪。
    var firstAttemptRawOutput: String?
}

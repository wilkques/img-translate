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

    /// 這塊的譯文是哪條路線產生的。
    var source: TranslationSource = .none
    /// 整頁路線對位到的項目編號(模型給的 BLOCK 編號)。
    var matchedItemIndex: Int?
    /// 對位的字串相似度分數。印在除錯清單上,讓接受門檻可以用實測數字校準,
    /// 而不是繼續用猜的。
    var matchScore: Double?

    /// 清掉這塊所有翻譯相關欄位,只留 Vision 定位資訊。
    ///
    /// 為什麼需要:VLM 模型選單新增後發現,切換/重新下載模型如果失敗,畫面上
    /// 還是會留著「上一顆模型」跑出來的舊翻譯結果——因為換模型不會觸發
    /// `runPipeline()` 重跑(`.task(id:)` 的 key 不含模型選擇),`blocks` 沒被
    /// 重置。裝機實測就踩到這個:Gemma 4 載入失敗,但畫面誤導成「翻譯成功」,
    /// 其實是 Qwen3-VL 上一輪的殘留結果。換模型、或載入失敗時都要呼叫這個,
    /// 不要讓不同模型的結果混在一起。
    mutating func resetTranslation() {
        recognizedText = nil
        translatedText = nil
        rawOutput = nil
        usedWiderContextRetry = false
        firstAttemptRawOutput = nil
        source = .none
        matchedItemIndex = nil
        matchScore = nil
    }
}

/// 譯文的來源路線,除錯清單顯示用。
enum TranslationSource: String {
    case none = "—"
    case wholePage = "整頁"
    case regionFallback = "逐塊"
}

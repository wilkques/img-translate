import CoreGraphics

/// 一個文字區塊交給 VLM 讀圖 + 翻譯的結果。
struct ImageRegionTranslation {
    /// VLM 自己從圖片讀出來的原文(跟 Vision 的辨識結果分開存,除錯對照用)
    var recognizedText: String
    /// 目標語言譯文
    var translatedText: String
    /// 模型原始輸出,格式解析失敗時用來看發生什麼事
    var rawOutput: String
    /// 有沒有走過「寬範圍裁圖」的重試路線。
    ///
    /// 這個欄位存在的理由:先前連續好幾輪裝機測試,不管是主要路線失敗還是重試也
    /// 失敗,畫面上都只顯示同一句「[生成失敗:輸出異常重複]」,完全看不出重試到底
    /// 有沒有跑、跑出什麼——等於在沒有資訊的情況下改 prompt/參數瞎猜。
    var usedWiderContextRetry: Bool = false
    /// 走過重試時,主要路線(緊裁圖)那次的原始輸出,用來跟重試的輸出對照。
    var firstAttemptRawOutput: String?
}

/// 讀圖翻譯引擎的介面。
///
/// 刻意不改動既有的 `TranslationEngine`(`[String] -> [String]`,純文字):那個協定
/// 描述的是「純文字翻譯」這件事,語意沒有錯,只是不再是唯一路線。兩個協定並存,
/// `ContentView` 用一個切換讓 Cyril 在同一張圖上直接對照兩條路線的結果。
///
/// 介面刻意做成一次一塊、不是 `[CGImage] -> [Result]`:VLM 每塊要幾秒鐘,一次回傳
/// 全部會讓使用者盯著空白畫面等很久。呼叫端自己 loop、每完成一塊就更新一次畫面。
protocol ImageTranslationEngine {
    /// - Parameters:
    ///   - region: 緊貼文字的裁圖(擴邊後),主要路線用這張。
    ///   - widerContext: 同一個位置、但擴邊範圍大很多的裁圖(涵蓋整個對話框/分鏡),
    ///     只在主要路線判定生成失敗時的重試才用得到——見 `VLMTranslationEngine`
    ///     裡的裝機實測記錄:同一顆模型透過 Locally AI 看整張圖能正確讀出文字,
    ///     但我們裁太緊、只給孤立的一小塊字時會卡生成迴圈,問題可能出在「缺乏上下文」
    ///     而不是 prompt 措辭。傳 `nil` 表示呼叫端沒有更大範圍可用,retry 就沿用
    ///     `region`。
    func translateRegion(
        _ region: CGImage,
        widerContext: CGImage?,
        from source: String,
        to target: String
    ) async throws -> ImageRegionTranslation

    /// 整頁一次讀完:模型看到完整的分鏡與對話框上下文,依閱讀順序列出頁面上所有
    /// 文字的「原文 + 譯文」。
    ///
    /// 為什麼要有這條路線:裝機證據顯示同級甚至更小的模型(Gemma 4 E2B、Qwen3.5 4B)
    /// 透過 Locally AI **看整張圖**就能正確讀出我們一直失敗的狀聲詞,而我們餵的是
    /// 孤立的一小塊裁圖。八輪只調 prompt/溫度都無效之後,「模型看到多大範圍」才是
    /// 真正沒被檢驗過的變因。
    ///
    /// 回傳值**不含座標**——座標永遠來自 Vision,呼叫端負責把清單配回 bbox。
    /// 回傳 `nil` 代表這個引擎不支援整頁路線,呼叫端直接走逐塊路線。
    func translatePage(
        _ page: CGImage,
        expectedBlockCount: Int,
        from source: String,
        to target: String
    ) async throws -> ImagePageTranslation?
}

extension ImageTranslationEngine {
    func translatePage(
        _ page: CGImage,
        expectedBlockCount: Int,
        from source: String,
        to target: String
    ) async throws -> ImagePageTranslation? { nil }
}

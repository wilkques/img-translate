import CoreGraphics

/// 一個文字區塊交給 VLM 讀圖 + 翻譯的結果。
struct ImageRegionTranslation {
    /// VLM 自己從圖片讀出來的原文(跟 Vision 的辨識結果分開存,除錯對照用)
    var recognizedText: String
    /// 目標語言譯文
    var translatedText: String
    /// 模型原始輸出,格式解析失敗時用來看發生什麼事
    var rawOutput: String
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
}

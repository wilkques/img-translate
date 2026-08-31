import Foundation

/// 整頁一次讀圖翻譯裡的其中一個文字項目。
///
/// 這個型別**刻意沒有座標**:座標一律來自 Vision 的 boundingBox(那是「原地回填」
/// 唯一可信的來源),這裡只負責「模型讀到什麼 / 翻成什麼」。要綁到哪一個 bbox 是
/// 呼叫端對位的事,不是模型說了算。
struct PageTextItem {
    /// 模型自己給的 BLOCK 編號(1-based);模型沒給就用出現順序補上。
    var index: Int
    /// 在整份輸出裡的出現順序(0-based)。對位用的是這個,不是 `index`——
    /// 模型偶爾會把編號寫錯或跳號,但出現順序永遠是可信的。
    var order: Int
    var original: String
    var translated: String
    /// 這一項自己的原始輸出片段,除錯清單顯示用。
    var rawSlice: String = ""
    /// 譯文被判定為重複迴圈或空白 → 呼叫端視為「這塊沒翻到」,退回逐塊路線。
    var isDegenerate: Bool = false
}

/// 整頁一次呼叫的完整結果。
struct ImagePageTranslation {
    var items: [PageTextItem]
    /// 模型完整原始輸出。這是整輪最重要的除錯產物——一張截圖就能同時看出
    /// 模型有沒有讀對難字、有沒有卡迴圈、總共列了幾塊、順序是什麼,
    /// 所以除錯清單要**完整顯示不截斷**。
    var rawOutput: String
}

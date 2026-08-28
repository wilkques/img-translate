/// 翻譯引擎的可切換介面。目前唯一實作是 `LocalLLMTranslationEngine`(MLX Swift 本機模型)。
/// 系統內建 Translation framework 曾經試過,已確認在 LiveContainer 側載環境下會永遠卡住
/// (session.translations(from:) 卡死不回應也不報錯),已移除。
protocol TranslationEngine {
    /// 依序翻譯多段文字,回傳陣列順序需與輸入一致
    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String]
}

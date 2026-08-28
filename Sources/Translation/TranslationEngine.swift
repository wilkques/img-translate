/// 翻譯引擎的可切換介面。目前有兩個實作:
/// - `AppleTranslationEngine`:系統內建 Translation framework,零額外記憶體壓力
/// - `LocalLLMTranslationEngine`:之後接 MLX Swift(Gemma/Qwen)的位置,這次先留空殼
protocol TranslationEngine {
    /// 依序翻譯多段文字,回傳陣列順序需與輸入一致
    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String]
}

/// 之後要接 MLX Swift(Gemma E2B / Qwen 4B 本機模型)的位置。
/// LiveContainer 記憶體上限已經驗證過綽綽有餘(見 `lc-memprobe` 專案,掛
/// increased-memory-limit entitlement 後約 6GB 可用),這裡先留介面卡槽,
/// 這次疊字效果驗證不實作真正的模型推理。
final class LocalLLMTranslationEngine: TranslationEngine {
    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] {
        // TODO: 接 MLX Swift,載入 Gemma E2B / Qwen 4B 做本機推理翻譯
        texts.map { "[本機模型尚未接上] \($0)" }
    }
}

import Foundation

/// 語言代碼 → 完整英文語言名稱,給 VLM 的 prompt 用。
///
/// ⚠️ 刻意跟 `LocalLLMTranslationEngine` 自己的對照表分開、不共用:那份是
/// TranslateGemma 的 `<<<source>>>` 分隔符號格式已經裝機驗證過的字串(例如
/// "Chinese (Traditional)"),VLM 這邊用的是一般自然語言 prompt,格式要求不同
/// (這裡用 "Traditional Chinese")。共用一份對照表換來的「不重複」,遠不如
/// 保留兩份分開修改來得安全——改一份不會意外動到另一條已驗證的路線。
enum LanguageNames {
    private static let map: [String: String] = [
        "en": "English",
        "es": "Spanish",
        "ja": "Japanese",
        "ko": "Korean",
        "fr": "French",
        "de": "German",
        "zh-Hans": "Simplified Chinese",
        "zh-Hant": "Traditional Chinese",
        "zh-Hant-TW": "Traditional Chinese",
        "zh-TW": "Traditional Chinese",
        "zh-CN": "Simplified Chinese",
    ]

    static func name(for code: String) throws -> String {
        if let mapped = map[code] { return mapped }
        if let base = code.split(separator: "-").first.map(String.init),
           let mapped = map[base] {
            return mapped
        }
        throw LocalLLMError.unsupportedLanguage(code)
    }
}

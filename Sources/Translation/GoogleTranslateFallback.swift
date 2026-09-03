import Foundation

/// ⚠️ 2026-09-03:**架構決定的例外**——這個專案從一開始的紅線是「100% 本機
/// 端上運算,不接雲端 LLM、不上傳圖片給第三方」(Cyril 早期明確拍板過,理由
/// 是隱私+免費,見 README 全篇「本機 MLX 模型」的論述)。這次 Cyril 主動要求
/// 「本機模型翻不出來就用 Google 翻譯」,是對那條紅線開的一個**範圍很窄的
/// 例外**,不是整個推翻:
///
/// - **只送文字,不送圖片**——本機 VLM 已經讀出原文(或至少 Vision OCR 有
///   讀到什麼),只有「翻譯」這個步驟失敗時才觸發,送出去的是幾個字的
///   文字字串,不是漫畫圖片本身,隱私暴露面遠小於「送雲端 LLM 讀圖」
/// - **只在本機模型多次重試都失敗後才觸發**(見 `TranslationRequestCoordinator`
///   的呼叫點),不是預設路徑,平常翻得出來就完全不會呼叫這裡
/// - **用 Google 翻譯網頁版底層的免費公開端點**(`translate_a/single`),
///   不是申請 API key 的官方 Cloud Translation API——這不是 Google 官方
///   支援的用法,理論上隨時可能被擋掉或改格式,失敗就直接回傳 `nil`,
///   呼叫端當作「這條路也救不回來」處理,不會讓 App 崩潰或卡住
enum GoogleTranslateFallback {
    /// 我們內部的語言代碼(給 VLM prompt/Vision 用)在中文這裡跟 Google
    /// 翻譯的代碼對不上,需要轉換;其餘語言(es/en/ja/ko/fr/de)代碼一致,
    /// 直接透傳。
    private static let googleLanguageCode: [String: String] = [
        "zh-Hans": "zh-CN",
        "zh-Hant": "zh-TW",
        "zh-Hant-TW": "zh-TW",
    ]

    private static func code(for internalCode: String) -> String {
        googleLanguageCode[internalCode] ?? internalCode
    }

    /// 回傳 `nil` 代表這條路也失敗(網路問題、格式解析不出來、或翻譯結果是
    /// 空字串),呼叫端維持原本的失敗訊息,不要用 `nil` 硬湊一個空字串疊上去。
    static func translate(_ text: String, from source: String, to target: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: code(for: source)),
            URLQueryItem(name: "tl", value: code(for: target)),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: trimmed),
        ]
        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            // 回應格式是不規則巢狀陣列,不是乾淨的物件,例如:
            // [[["翻譯結果","原文",null,null,1],["第二句翻譯","第二句原文",...]],null,"es"]
            // 每個分段陣列的第 0 個元素才是翻譯文字,長文字會被拆成多段,
            // 全部接起來才是完整翻譯。
            guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let segments = root.first as? [Any] else { return nil }
            let translated = segments
                .compactMap { ($0 as? [Any])?.first as? String }
                .joined()
            return translated.isEmpty ? nil : translated
        } catch {
            return nil
        }
    }
}

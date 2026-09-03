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
///
/// ⚠️ 2026-09-03 裝機驗證發現:這個端點真的會被 Google 的濫用防護擋下來
/// (`HTTP 429`,"your computer or network may be sending automated
/// queries")——從這個開發環境直接測試就重現了,「翻譯整話」模式短時間內
/// 對同一個端點連續呼叫好幾次,很可能就是觸發門檻。改成 `actor`(不是
/// `enum`)是為了帶一份呼叫間隔的狀態:每次呼叫前如果距離上次呼叫不到
/// `currentInterval` 秒就先等,遇到 429 就把間隔加倍(簡易指數退避,上限
/// `maxInterval`),成功一次就退回基準值。這是一個緩解嘗試,**不保證能完全
/// 避開**——如果裝置所在網路的 IP 信譽已經被標記,再怎麼放慢還是可能被擋,
/// 屆時要考慮換官方付費 API 或接受這條備援路線不穩定。
actor GoogleTranslateFallback {
    static let shared = GoogleTranslateFallback()

    /// 呼叫端(`TranslationRequestCoordinator`)完全不用改——still 呼叫這個
    /// 型別層級的 `translate`,節流狀態全部關在 `shared` instance 裡面。
    static func translate(_ text: String, from source: String, to target: String) async -> String? {
        await shared.performTranslate(text, from: source, to: target)
    }

    /// 我們內部的語言代碼(給 VLM prompt/Vision 用)在中文這裡跟 Google
    /// 翻譯的代碼對不上,需要轉換;其餘語言(es/en/ja/ko/fr/de)代碼一致,
    /// 直接透傳。
    private let googleLanguageCode: [String: String] = [
        "zh-Hans": "zh-CN",
        "zh-Hant": "zh-TW",
        "zh-Hant-TW": "zh-TW",
    ]

    private func code(for internalCode: String) -> String {
        googleLanguageCode[internalCode] ?? internalCode
    }

    private var lastCallAt: Date?
    private var currentInterval: TimeInterval = 2.0
    private static let baseInterval: TimeInterval = 2.0
    private static let maxInterval: TimeInterval = 20.0

    /// 回傳 `nil` 代表這條路也失敗(網路問題、被 429 擋、格式解析不出來、
    /// 或翻譯結果是空字串),呼叫端維持原本的失敗訊息,不要用 `nil` 硬湊一個
    /// 空字串疊上去。
    private func performTranslate(_ text: String, from source: String, to target: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        await waitForThrottle()

        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: code(for: source)),
            URLQueryItem(name: "tl", value: code(for: target)),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: trimmed),
        ]
        guard let url = components?.url else { return nil }

        lastCallAt = Date()
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 429 {
                    currentInterval = min(currentInterval * 2, Self.maxInterval)
                }
                return nil
            }
            currentInterval = Self.baseInterval
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

    private func waitForThrottle() async {
        guard let last = lastCallAt else { return }
        let elapsed = Date().timeIntervalSince(last)
        let remaining = currentInterval - elapsed
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }
}

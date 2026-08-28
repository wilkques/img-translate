import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// MLX Swift 本機模型翻譯引擎。
///
/// 模型:mlx-community/translategemma-4b-it-4bit_immersive-translate(TranslateGemma 4B 翻譯
/// 專用微調,重新包過 chat template 給一般推理引擎用)。
///
/// ⚠️ 這裡有個踩過的坑:TranslateGemma **官方**的 chat template 要求 `content` 是結構化 list
/// (`[{type, source_lang_code, target_lang_code, text}]`),不是純字串——用
/// `UserInput.additionalContext` 塞語言代碼進去會讓 Jinja 渲染直接報錯
/// (`Jinja.TemplateException`),因為官方模板根本不吃這種格式。
/// `_immersive-translate` 這個變體版本改成純文字分隔符號格式:
/// `<<<source>>>{語言全名}<<<target>>>{語言全名}<<<text>>>{原文}`,當一般字串訊息送即可,
/// 不需要 additionalContext、不需要結構化 content——這正好對得上 mlx-swift-lm 的
/// `UserInput(chat:)` 這種簡單 API。**注意語言要用完整英文名稱("English"/"French"),不是代碼。**
@MainActor
final class LocalLLMTranslationEngine: ObservableObject, TranslationEngine {

    enum Phase: Equatable {
        case idle
        case downloading(Double)          // 0.0 ~ 1.0
        case loadingWeights
        case ready
        case translating(done: Int, total: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// 顯示用的模型大小估計(給下載提示用)
    static let approximateDownloadBytes: Int64 = 2_300_000_000

    /// mlx-swift-lm 的 LLMRegistry 沒有內建 TranslateGemma 的 preset,手動建
    /// ModelConfiguration 指向 HF repo——套件的通用 gemma3 型別處理器就能載入,
    /// 不需要 registry 裡有現成項目。
    private static let configuration = ModelConfiguration(
        id: "mlx-community/translategemma-4b-it-4bit_immersive-translate")

    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?

    /// temperature 0 = 貪婪解碼,翻譯要的是穩定不是創意。
    /// maxTokens 256 對一個漫畫對話框綽綽有餘,同時也是防呆(模型跑飛時不會無限生成)。
    private let generateParameters = GenerateParameters(
        maxTokens: 256,
        temperature: 0.0
    )

    // MARK: - TranslationEngine

    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        let sourceName = try Self.languageName(for: source)
        let targetName = try Self.languageName(for: target)

        let container = try await ensureLoaded()

        var results: [String] = []
        results.reserveCapacity(texts.count)

        for (index, text) in texts.enumerated() {
            phase = .translating(done: index, total: texts.count)

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                results.append(text)
                continue
            }
            // ⚠️ 實驗性提示,兩種都可能被模型當成內容一起吐出來,所以一律過
            // stripLeakedInstruction() 做保險過濾(見下方函式)。
            //
            // (1) 狀聲詞/吼叫聲(GRRRAAAGH 這種)會被翻成「怒吼」這種描述詞,不是
            //     漫畫慣用的擬聲字轉寫,用「連續重複字母」偵測挑出來加音譯指示。
            // (2) 一般對話預設翻得偏書面/正式(「你很吵」),想要更貼近口語漫畫台詞
            //     的語氣(「你吵死了」這種),加一句語氣指示——TranslateGemma 是翻譯
            //     專用微調模型,語氣調整的服從度沒把握,需要裝機驗證有沒有效果。
            let isOnomatopoeia = Self.looksLikeOnomatopoeia(trimmed)
            let body: String
            if isOnomatopoeia {
                body = "(This is a sound effect / battle cry, not a real word. Output ONLY the phonetic transliteration into \(targetName) — no explanation, no label, no parentheses, nothing else.) \(trimmed)"
            } else {
                body = "(Translate in a natural, casual spoken tone as comic book dialogue, not formal written language. Output ONLY the translation — no explanation, no label, no parentheses, nothing else.) \(trimmed)"
            }
            let prompt = "<<<source>>>\(sourceName)<<<target>>>\(targetName)<<<text>>>\(body)"
            let rawTranslated = try await Self.generateOne(
                prompt,
                container: container,
                parameters: generateParameters
            )
            var translated = Self.stripLeakedInstruction(rawTranslated)
            // 原文用「...」表示語氣未完/拖長音,保留這個語感——模型常常會把它收成句號。
            if (trimmed.hasSuffix("...") || trimmed.hasSuffix("…")), translated.hasSuffix("。") {
                translated = String(translated.dropLast()) + "……"
            }
            results.append(translated.isEmpty ? text : translated)
        }

        phase = .ready
        // 每一批做完釋放 Metal buffer cache,避免在 LiveContainer 的記憶體上限下累積。
        MLX.Memory.clearCache()
        return results
    }

    // MARK: - 生成

    private nonisolated static func generateOne(
        _ prompt: String,
        container: ModelContainer,
        parameters: GenerateParameters
    ) async throws -> String {
        // 純字串訊息,語言資訊已經用 <<<source>>>/<<<target>>>/<<<text>>> 分隔符號
        // 包在 prompt 裡了(見 translate() 組字串那行),不需要 additionalContext。
        let userInput = UserInput(chat: [.user(prompt)])

        let lmInput = try await container.prepare(input: userInput)
        let stream = try await container.generate(input: lmInput, parameters: parameters)

        var output = ""
        for await event in stream {
            if let chunk = event.chunk {
                output += chunk
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 載入(含下載)

    @discardableResult
    func ensureLoaded() async throws -> ModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }

        // 限制 MLX 的 buffer cache,LiveContainer 記憶體上限雖然實測有 ~6GB,
        // 但模型權重就佔 2.2GB,不設限的話 cache 會一路長。
        MLX.Memory.cacheLimit = 256 * 1024 * 1024

        let configuration = Self.configuration

        let task = Task.detached(priority: .userInitiated) { [weak self] () throws -> ModelContainer in
            if !LocalModelStore.isModelPresent(),
               let available = LocalModelStore.availableBytesForImportantUsage(),
               available < Self.approximateDownloadBytes + 500_000_000 {
                throw LocalLLMError.insufficientDiskSpace(
                    needed: Self.approximateDownloadBytes, available: available)
            }

            let downloader = HubSnapshotDownloader(try LocalModelStore.makeHubClient())
            let tokenizerLoader = HuggingFaceTokenizerLoader()

            await MainActor.run { self?.phase = .downloading(0) }

            let container = try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: configuration
            ) { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    self?.phase = fraction >= 1.0 ? .loadingWeights : .downloading(fraction)
                }
            }

            await MainActor.run { self?.phase = .ready }
            return container
        }

        loadTask = task
        do {
            let loaded = try await task.value
            container = loaded
            return loaded
        } catch {
            loadTask = nil                      // 允許重試
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 釋放模型(切回 Apple 引擎時呼叫,把 2.2GB 還給系統)
    func unload() {
        container = nil
        loadTask?.cancel()
        loadTask = nil
        MLX.Memory.clearCache()
        phase = .idle
    }

    // MARK: - 語言代碼

    /// `<<<source>>>`/`<<<target>>>` 這個分隔符號格式要的是**完整英文語言名稱**
    /// (官方範例用 "English"/"French"),不是 BCP-47 代碼——這點跟原本官方結構化
    /// content 格式(吃 `source_lang_code` 這種代碼)不一樣,容易搞混。
    /// ContentView 語言選單用的代碼對應到這裡。
    private static let languageNameMap: [String: String] = [
        "en": "English",
        "es": "Spanish",
        "ja": "Japanese",
        "ko": "Korean",
        "fr": "French",
        "de": "German",
        "zh-Hans": "Chinese (Simplified)",
        "zh-Hant": "Chinese (Traditional)",
        "zh-Hant-TW": "Chinese (Traditional)",
        "zh-TW": "Chinese (Traditional)",
        "zh-CN": "Chinese (Simplified)",
    ]

    /// 語言無關的簡單偵測法:文字裡有沒有連續 3 個以上相同字母(不分大小寫),
    /// 例如 GRRRAAAGH、AAAAH、ZZZZ——漫畫狀聲詞/吼叫聲常見這種寫法,一般句子幾乎不會。
    private static func looksLikeOnomatopoeia(_ text: String) -> Bool {
        let letters = Array(text.uppercased().filter { $0.isLetter })
        guard letters.count >= 3 else { return false }
        var runLength = 1
        for i in 1..<letters.count {
            if letters[i] == letters[i - 1] {
                runLength += 1
                if runLength >= 3 { return true }
            } else {
                runLength = 1
            }
        }
        return false
    }

    /// 保險用:狀聲詞的音譯指示偶爾會被模型原樣複誦回來,格式通常是開頭一個
    /// 中/英文括號包住的說明(「(模擬聲音:...)」/「(Note: ...)」),把這種開頭
    /// 括號整段砍掉,只留後面真正的轉寫結果。抓不到括號就原樣回傳,不誤殺正常輸出。
    private static func stripLeakedInstruction(_ text: String) -> String {
        let opens: [Character] = ["(", "（"]
        let closes: [Character] = [")", "）"]
        guard let first = text.first, opens.contains(first) else { return text }
        guard let closeIndex = text.firstIndex(where: { closes.contains($0) }) else { return text }
        let remainder = text[text.index(after: closeIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? text : remainder
    }

    static func languageName(for code: String) throws -> String {
        if let mapped = languageNameMap[code] { return mapped }
        // 退一步:砍掉區域子標籤再試一次(例如 "pt-BR" -> "pt")
        if let base = code.split(separator: "-").first.map(String.init),
           let mapped = languageNameMap[base] {
            return mapped
        }
        throw LocalLLMError.unsupportedLanguage(code)
    }
}

enum LocalLLMError: LocalizedError {
    case unsupportedLanguage(String)
    case insufficientDiskSpace(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let code):
            return "本機模型不支援語言代碼「\(code)」"
        case .insufficientDiskSpace(let needed, let available):
            let n = needed / 1_000_000_000, a = available / 1_000_000_000
            return "磁碟空間不足:需要約 \(n)GB,可用 \(a)GB"
        }
    }
}

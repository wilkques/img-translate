import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// MLX Swift 本機模型翻譯引擎。
///
/// 模型:mlx-community/translategemma-4b-it-4bit(2.22GB,Google TranslateGemma 翻譯專用微調)
///
/// 為什麼不用自己寫「只輸出翻譯、不要解釋」的 system prompt:
/// TranslateGemma 的 chat template 已經內建這段指示。`LLMRegistry.translategemma_4b_it_4bit`
/// 掛的訊息產生邏輯會把 `UserInput.additionalContext` 裡的 source_lang_code/target_lang_code
/// 塞進 template,template 自己會渲染出完整的翻譯指示。我們只要餵原文 + 兩個語言代碼即可。
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

    private static let configuration = LLMRegistry.translategemma_4b_it_4bit

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

        let sourceCode = try Self.templateLanguageCode(for: source)
        let targetCode = try Self.templateLanguageCode(for: target)

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
            let translated = try await Self.generateOne(
                trimmed,
                container: container,
                source: sourceCode,
                target: targetCode,
                parameters: generateParameters
            )
            results.append(translated.isEmpty ? text : translated)
        }

        phase = .ready
        // 每一批做完釋放 Metal buffer cache,避免在 LiveContainer 的記憶體上限下累積。
        MLX.GPU.clearCache()
        return results
    }

    // MARK: - 生成

    private nonisolated static func generateOne(
        _ text: String,
        container: ModelContainer,
        source: String,
        target: String,
        parameters: GenerateParameters
    ) async throws -> String {
        let userInput = UserInput(
            chat: [.user(text)],
            additionalContext: [
                "source_lang_code": source,
                "target_lang_code": target,
            ]
        )

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
        MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)

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
        MLX.GPU.clearCache()
        phase = .idle
    }

    // MARK: - 語言代碼

    /// TranslateGemma 的 chat template 內建一張語言表,查不到的代碼會讓 Jinja 渲染爆掉。
    /// 已知有 en/es/ja/ko/fr/de/zh-Hans/zh-Hant,**沒有 zh-Hant-TW**
    /// (ContentView 目前用的就是這個),所以必須映射。
    private static let codeMap: [String: String] = [
        "en": "en",
        "es": "es",
        "ja": "ja",
        "ko": "ko",
        "fr": "fr",
        "de": "de",
        "zh-Hans": "zh-Hans",
        "zh-Hant": "zh-Hant",
        "zh-Hant-TW": "zh-Hant",
        "zh-TW": "zh-Hant",
        "zh-CN": "zh-Hans",
    ]

    static func templateLanguageCode(for code: String) throws -> String {
        if let mapped = codeMap[code] { return mapped }
        // 退一步:砍掉區域子標籤再試一次(例如 "pt-BR" -> "pt")
        if let base = code.split(separator: "-").first.map(String.init),
           let mapped = codeMap[base] {
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

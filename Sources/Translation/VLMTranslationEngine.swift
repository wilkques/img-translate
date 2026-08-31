import CoreGraphics
import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM

/// 用多模態模型(VLM)直接讀「從原圖裁下來的文字區塊」,一次完成「讀字 + 翻譯」。
///
/// 為什麼要走這條路:Apple Vision OCR 對漫畫手寫感粗體字辨識不可靠(實測
/// `¡UWA! ¡¡UWAA!!` 被認成 `¡LIWA! ¡¡LWAA!!`),但 Vision 的 boundingBox 是可靠的、
/// 也是「原地回填」唯一的座標來源。所以:位置 = Vision,文字內容 = VLM。
///
/// 模型:lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit(3.09GB / 4-bit)。
/// 這個 id 在 `VLMRegistry` 有內建 preset,直接用 preset 才會帶到
/// `extraEOSTokens: ["<|im_end|>"]`——漏掉的話生成不會停,每塊都跑滿 maxTokens,
/// 速度直接爛掉。
@MainActor
final class VLMTranslationEngine: ObservableObject, ImageTranslationEngine {

    enum Phase: Equatable {
        case idle
        case downloading(Double)          // 0.0 ~ 1.0
        case loadingWeights
        case warmingUp                    // 第一次推理會編 Metal pipeline,先用假圖吃掉
        case ready
        case translating(done: Int, total: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// 顯示用的下載大小估計:safetensors 3.09GB + tokenizer/config 約 0.1GB
    static let approximateDownloadBytes: Int64 = 3_200_000_000

    private static let configuration = VLMRegistry.qwen3VL4BInstruct4Bit

    // 記憶體/速度不夠時,只換這行就能降級,其他程式碼不用動
    // (三個候選都走 Qwen*VLProcessor / VLMModelFactory):
    //   VLMRegistry.qwen2_5VL3BInstruct4Bit   // mlx-community/Qwen2.5-VL-3B-Instruct-4bit
    //   ModelConfiguration(id: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
    //                      extraEOSTokens: ["<|im_end|>"])   // 記憶體逃生梯,1.78GB

    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?

    /// ⚠️ 裝機實測歷程:
    /// 1. temperature 0(純貪婪解碼)在難讀的裁圖上會卡進「同一個字元一直重複」的
    ///    生成迴圈(例如整段輸出變成一長串 "iiiii...")。改用一個很小的非零溫度
    ///    降低卡迴圈機率,同時 `parse()` 加了退化輸出偵測當保險——裝機驗證這道
    ///    偵測有效,抓到重複迴圈會顯示明確的失敗訊息而不是垃圾文字。
    /// 2. 但把 maxTokens 從 128 砍到 80(想讓迴圈早點失敗)砍過頭了:合併過多行的
    ///    對話框,模型光複誦完 Step 1 的原文就可能吃掉大半額度,還沒寫到
    ///    Step 2 翻譯就被截斷(不是字元重複,退化偵測抓不到這種失敗模式)。
    ///    既然退化偵測已經頂住了真正的迴圈,maxTokens 拉回來給多行框多一點空間。
    private let generateParameters = GenerateParameters(
        maxTokens: 150,
        temperature: 0.2
    )

    /// ⚠️ 裝機實測歷程(第 3 輪):maxTokens 拉回 150 後,合併多行框不再被截斷,
    /// 但含大量重複字母的狀聲詞("UWAAA"、"GRRRRRRAAAAGH")本身就在提示模型「接下來
    /// 繼續重複同一個字」,Step 1 要求逐字複誦這種輸入時偶爾還是會卡進重複迴圈,被
    /// `isDegenerateOutput` 抓到。這兩塊是裝機實測目前唯一還會卡住的案例,不值得把
    /// 常駐溫度整體拉高(會犧牲另外兩塊已經翻對的句子的穩定性)——改成只有偵測到
    /// 退化輸出時,原地重試一次、用更高溫度打散貪婪路徑。
    private let retryParameters = GenerateParameters(
        maxTokens: 150,
        temperature: 0.7
    )

    /// 送進 VLM 前把裁切圖的長邊縮放到這個尺寸。
    ///
    /// 這是必要條件不是優化:Qwen3-VL 的 processor 不吃 `UserInput.Processing` 的
    /// minPixels/maxPixels,唯一能控制解析度的槓桿是 `resize`。不設的話,小裁圖
    /// 會被縮到只剩幾十像素,字整個糊掉,VLM 一樣讀錯。`MediaProcessing` 內部用
    /// 等比縮放(可放大也可縮小),傳一個正方形目標等於「長邊 fit 到 N」。
    ///
    /// 768:一個典型對話框裁圖在筆畫清晰度跟推理速度之間的折衷。太慢就調 512,
    /// 讀不出來就調 1024。
    private static let visionLongEdge: CGFloat = 768

    // MARK: - ImageTranslationEngine

    func translateRegion(
        _ region: CGImage,
        from source: String,
        to target: String
    ) async throws -> ImageRegionTranslation {
        let sourceName = try LanguageNames.name(for: source)
        let targetName = try LanguageNames.name(for: target)
        let container = try await ensureLoaded()
        let prompt = Self.makePrompt(source: sourceName, target: targetName)

        let raw = try await Self.generateOne(
            image: region, prompt: prompt, container: container, parameters: generateParameters)

        // 卡進重複迴圈的都是同一小撮「來源文字本身就重複字母」的難字,原地用一個完全
        // 不要求逐字複誦原文的簡化 prompt 重試一次(見 makeRetryPrompt 註解)。
        if Self.isDegenerateOutput(raw) {
            let retryRaw = try await Self.generateOne(
                image: region,
                prompt: Self.makeRetryPrompt(target: targetName),
                container: container,
                parameters: retryParameters)
            return Self.parse(retryRaw)
        }

        return Self.parse(raw)
    }

    /// 呼叫端跑完整頁之後呼叫,把 Metal buffer cache 還回去。
    /// 不要每塊都叫——那會逼 MLX 每次重新配置緩衝區,反而更慢。
    func finishPage() {
        MLX.Memory.clearCache()
    }

    // MARK: - Prompt

    /// 提示詞設計要點:
    /// - 明講「這是從漫畫頁裁下來的一小塊」,模型才不會去描述畫面內容
    /// - 明講「可能是狀聲詞不是真的單字」,並要求音譯——這條在純文字模型
    ///   (TranslateGemma,窄用途翻譯微調)上曾經翻車翻成錯的語言,但 Qwen3-VL
    ///   是通用 instruct 模型,理論上吃得住多步驟指令,裝機驗證有沒有效果
    /// - 要求輸出兩行(ORIGINAL/TRANSLATION):補上「判斷是辨識錯還是翻譯錯」的
    ///   除錯需求,成本只有幾個 token
    ///
    /// ⚠️ 裝機實測歷程:曾經試過把 TRANSLATION 排到 ORIGINAL 前面,理論上是想讓
    /// 模型卡在複誦原文時至少先寫出翻譯——裝機驗證**反而更差**:不只兩個難字沒被
    /// 救到(其中一個變成把原文原封不動當「譯文」吐回來),連原本穩定翻對的兩句
    /// 正常句子都被这個改動搞壞(輸出變成截斷的 "TRANSLA..." 或譯文跟原文黏在一起)。
    /// 判斷是先讀原文再翻譯這個「兩步驟」本身在助攻正常句子的翻譯品質,問題只出在
    /// 兩個重複字母極端多的難字上——所以**改回原本驗證過穩定的順序**,難字改交給
    /// 下面 `makeRetryPrompt` 這個完全不同、更簡化的 retry-only prompt 處理,不動
    /// 這個已經驗證過對一般句子有效的主要 prompt。
    private static func makePrompt(source: String, target: String) -> String {
        """
        This image is one small text region cropped from a comic page. The text is \
        written in \(source), in a stylised hand-lettered bold font. It may be a sound \
        effect or a shout rather than a real word.

        Step 1. Read the text as it is drawn. Keep punctuation and inverted marks (¡ ¿). \
        Do not correct it into a real word. If a letter is repeated many times (a long \
        scream or sound effect), do NOT try to count the exact number of repeats — just \
        write a short natural amount (2-4 repeats is enough) and move on to Step 2.
        Step 2. Translate it into \(target). If it is a sound effect or a scream, \
        transliterate the sound into \(target) instead of translating its literal meaning.

        Reply with exactly two lines and nothing else, no explanation, no quotes:
        ORIGINAL: <the text you read>
        TRANSLATION: <the \(target) text>
        """
    }

    /// 只在主要 prompt 判定退化輸出(卡進重複迴圈)之後才用。刻意拿掉「逐字讀出
    /// 原文」這一步——那正是卡迴圈的根源(來源文字本身重複字母極多),既然已經
    /// 判定原文讀不出來也沒關係(這種案例反正是狀聲詞,讀不出精確原文不影響回填
    /// 使用者看到的翻譯結果),retry 只要求一件事:直接給音譯,不要求對照原文。
    private static func makeRetryPrompt(target: String) -> String {
        """
        This image is one small text region cropped from a comic page. It is a shout or \
        a sound effect written in a stylised hand-lettered bold font, possibly with many \
        repeated letters (for example a scream).

        Give a short, natural \(target) transliteration of the sound. Keep any repeated \
        sound short (2-4 repeats is enough) — do not try to match the exact number of \
        repeats in the image.

        Reply with exactly one line and nothing else, no explanation, no quotes:
        TRANSLATION: <the \(target) text>
        """
    }

    // MARK: - 生成

    private nonisolated static func generateOne(
        image: CGImage,
        prompt: String,
        container: ModelContainer,
        parameters: GenerateParameters
    ) async throws -> String {
        // UserInput.Image 只有 .ciImage/.url/.array 三種 case,沒有 .uiImage,
        // 所以直接從 CGImage 包 CIImage。
        let ciImage = CIImage(cgImage: image)

        var processing = UserInput.Processing()
        processing.resize = CGSize(width: Self.visionLongEdge, height: Self.visionLongEdge)

        // 跟純文字版唯一的差別:.user() 多帶 images:,外層多帶 processing:。
        // 圖片內容怎麼插進 chat template 是 Qwen3VLMessageGenerator/Qwen3VLProcessor
        // 自己處理的,呼叫端不用管。
        let userInput = UserInput(
            chat: [.user(prompt, images: [.ciImage(ciImage)])],
            processing: processing
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

    // MARK: - 輸出解析

    /// 寬鬆解析:抓得到 ORIGINAL:/TRANSLATION: 就拆兩欄,抓不到就把整段當譯文。
    /// 不做嚴格驗證——4B 模型偶爾不照格式是正常的,不能因此讓整塊變空白。
    ///
    /// ⚠️ 裝機實測抓到的失敗模式:貪婪解碼在難讀的裁圖上偶爾會卡進「同一個字元一直
    /// 重複」的生成迴圈(整段變成一長串 "iiiii..."),這種輸出裡通常也抓不到
    /// ORIGINAL:/TRANSLATION: 標籤,原本的 fallback(抓不到就整段當譯文)會把這坨
    /// 垃圾直接顯示出來。加一道退化偵測,抓到就回傳明確的失敗訊息而不是垃圾文字,
    /// 除錯清單上至少看得出「這塊生成失敗」而不是誤以為翻譯結果就長這樣。
    nonisolated static func parse(_ raw: String) -> ImageRegionTranslation {
        if isDegenerateOutput(raw) {
            return ImageRegionTranslation(
                recognizedText: "", translatedText: "[生成失敗:輸出異常重複]", rawOutput: raw)
        }

        var original = ""
        var translated = ""

        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let r = trimmed.range(of: "ORIGINAL:", options: [.caseInsensitive, .anchored]) {
                original = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let r = trimmed.range(of: "TRANSLATION:", options: [.caseInsensitive, .anchored]) {
                translated = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }

        if translated.isEmpty {
            translated = raw
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ImageRegionTranslation(recognizedText: original, translatedText: translated, rawOutput: raw)
    }

    /// 同一個非空白字元連續出現超過這個次數,判定生成卡進重複迴圈了。
    /// 一般正常語句(包含中文疊字、西班牙文重複字母的狀聲詞)不會連續重複這麼多次。
    private nonisolated static func isDegenerateOutput(_ raw: String, threshold: Int = 12) -> Bool {
        var runLength = 0
        var previous: Character?
        for ch in raw where !ch.isWhitespace {
            if ch == previous {
                runLength += 1
                if runLength >= threshold { return true }
            } else {
                runLength = 1
            }
            previous = ch
        }
        return false
    }

    // MARK: - 載入(含下載)

    @discardableResult
    func ensureLoaded() async throws -> ModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }

        // VLM 權重 3.1GB(比 TranslateGemma 的 2.2GB 大),cache 上限相對壓小一點。
        MLX.Memory.cacheLimit = 128 * 1024 * 1024

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

            // 跟 LLMModelFactory.loadContainer 完全同簽名——HuggingFaceBridge.swift/
            // LocalModelStore.swift 一行都不用改,只是換一個 factory。
            let container = try await VLMModelFactory.shared.loadContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: configuration
            ) { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    self?.phase = fraction >= 1.0 ? .loadingWeights : .downloading(fraction)
                }
            }

            // 第一次推理會編譯 Metal pipeline/配置圖像 tower 的緩衝區,可能多花十幾秒。
            // 用一張純白假圖先吃掉,不要讓「第一個對話框」背這個鍋。
            await MainActor.run { self?.phase = .warmingUp }
            _ = try? await Self.generateOne(
                image: Self.blankWarmupImage(),
                prompt: "Reply with the single word OK.",
                container: container,
                parameters: GenerateParameters(maxTokens: 2, temperature: 0.0)
            )

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

    private nonisolated static func blankWarmupImage() -> CGImage {
        let size = 64
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    /// 釋放模型(切回文字引擎時呼叫,把 3.1GB 還給系統——兩個模型不能同時載入)
    func unload() {
        container = nil
        loadTask?.cancel()
        loadTask = nil
        MLX.Memory.clearCache()
        phase = .idle
    }
}

import CoreGraphics
import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import UIKit

/// 用多模態模型(VLM)直接讀「從原圖裁下來的文字區塊」,一次完成「讀字 + 翻譯」。
///
/// 為什麼要走這條路:Apple Vision OCR 對漫畫手寫感粗體字辨識不可靠(實測
/// `¡UWA! ¡¡UWAA!!` 被認成 `¡LIWA! ¡¡LWAA!!`),但 Vision 的 boundingBox 是可靠的、
/// 也是「原地回填」唯一的座標來源。所以:位置 = Vision,文字內容 = VLM。
///
/// 模型可以在 app 裡切換(見 `VLMModelOption`),預設 lmstudio-community/
/// Qwen3-VL-4B-Instruct-MLX-4bit(3.09GB / 4-bit)。每個選項都要用 `VLMRegistry`
/// 內建 preset 或明講 `extraEOSTokens: ["<|im_end|>"]`——漏掉的話生成不會停,
/// 每塊都跑滿 maxTokens,速度直接爛掉。
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

    /// 2026-09-01:原本寫死 Qwen3-VL-4B 一顆,排查 UWA 這塊難字時發現 8/31 筆記裡
    /// 「模型/訓練資料差異」這個假設從頭到尾沒真正測過(Cyril 用 Locally AI 的
    /// Gemma 4/Qwen3.5 讀得出來,我們用的模型完全不同顆)。改成可選,不用每次
    /// 猜哪顆模型就要改程式碼重新編譯裝機。
    enum VLMModelOption: String, CaseIterable, Identifiable {
        case qwen3VL4B = "Qwen3-VL-4B"
        case qwen2_5VL3B = "Qwen2.5-VL-3B"
        case qwen3VL2B = "Qwen3-VL-2B"
        case gemma4E2B = "Gemma 4 E2B"
        case gemma4E4B = "Gemma 4 E4B"

        var id: String { rawValue }

        /// ⚠️ `gemma4_E2B_it_4bit`/`gemma4_E4B_it_4bit` 是透過網路搜尋找到的
        /// `VLMRegistry` preset 名稱,沒有管道直接讀到專案釘住版本
        /// (`mlx-swift-lm` 3.31.4)的原始碼逐字確認拼字——如果編譯錯誤說找不到
        /// 這個屬性,去對照該 tag 的 `VLMModelFactory.swift` 修正,不是程式邏輯
        /// 的問題。
        var configuration: ModelConfiguration {
            switch self {
            case .qwen3VL4B: return VLMRegistry.qwen3VL4BInstruct4Bit
            case .qwen2_5VL3B: return VLMRegistry.qwen2_5VL3BInstruct4Bit
            case .qwen3VL2B:
                return ModelConfiguration(
                    id: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
                    extraEOSTokens: ["<|im_end|>"])
            case .gemma4E2B: return VLMRegistry.gemma4_E2B_it_4bit
            case .gemma4E4B: return VLMRegistry.gemma4_E4B_it_4bit
            }
        }

        /// 顯示用的下載大小估計,只影響進度條準不準,不影響功能。Gemma 4 兩顆是
        /// 用有效參數量推算的粗估值(MatFormer 架構打包方式可能跟 dense 4-bit
        /// 不同),第一次真的下載完後應該回來對實際大小校正。
        var approximateDownloadBytes: Int64 {
            switch self {
            case .qwen3VL4B: return 3_200_000_000    // safetensors 3.09GB + tokenizer/config
            case .qwen2_5VL3B: return 2_000_000_000  // 待確認
            case .qwen3VL2B: return 1_780_000_000
            case .gemma4E2B: return 2_000_000_000    // 待確認,≈2B 有效參數
            case .gemma4E4B: return 3_500_000_000    // 待確認,≈4B 有效參數
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published var selectedModel: VLMModelOption = .qwen3VL4B
    /// 每個選項有沒有下載過,給「下載/移除」按鈕判斷要顯示哪一種。掃檔案系統有
    /// 成本,不即時輪詢——只在真的可能改變(app 啟動、下載完成、移除之後)才
    /// 呼叫 `refreshDownloadedModels()` 重新掃一次。
    @Published private(set) var downloadedModels: Set<VLMModelOption> = []

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
    /// 退化偵測抓到。這兩塊是裝機實測目前唯一還會卡住的案例,不值得把
    /// 常駐溫度整體拉高(會犧牲另外兩塊已經翻對的句子的穩定性)——改成只有偵測到
    /// 退化輸出時,原地重試一次、用更高溫度打散貪婪路徑。
    ///
    /// ⚠️ 裝機實測歷程(第 6 輪,意外發現):曾經測到「先翻譯再讀原文」+ temperature
    /// 0.2(也就是跟 `generateParameters` 一樣的溫度)這個組合,難字唯一一次生出
    /// 乾淨、不卡迴圈的輸出(雖然翻譯內容本身錯了,但沒有卡進字元重複)。反而後續
    /// 用 0.7 重試(不管是原本兩步驟 prompt 還是拿掉讀原文的簡化 prompt)每次都還是
    /// 卡迴圈。跟一般直覺(拉高溫度=打散貪婪路徑)相反的證據——對這顆 4-bit 小模型
    /// 在這種輸入上,0.7 看起來是在**加重**卡迴圈,不是緩解。retry 溫度改回 0.2,
    /// 只靠「拿掉讀原文步驟、縮短生成長度」這個變因來降低卡迴圈機率。
    ///
    /// ⚠️ 裝機實測(2026-09-01,retry 改餵整頁圖之後):把 `widerContext` 直接換成
    /// 整頁原圖後,retry 對頂部難字還是整段空轉純 `¡` 符號,跟裁圖範圍大小無關
    /// (範圍已經跟整頁路線完全一樣)。一度懷疑是 `maxTokens` 額度不夠(整頁路線
    /// 512、這裡只有 150),試著拉到 512——**假設被推翻,而且拉高還有副作用**:
    /// 重試原始輸出精準卡在新上限「共512字」,證實模型根本沒有要脫離迴圈的跡象,
    /// 不是「差一點撐過去」,額度大小不是這塊的瓶頸。更糟的是,同一輪跑起來的
    /// `YA BASTA...`(十幾輪來唯一一次)、`GRRRAAAGH` 譯文都跟著失常/跑掉——裝機
    /// 重跑「maxTokens 還是 150」的舊版本確認這兩塊立刻恢復穩定,坐實是拉高
    /// maxTokens 的副作用(推測是單一區塊生成時間拉長,拖累同一輪後續區塊的生成
    /// 穩定性)。改回 150,不留這個沒有好處、還有代價的改動。
    private let retryParameters = GenerateParameters(
        maxTokens: 150,
        temperature: 0.2
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

    /// retry 用更大的縮放目標,搭配 `widerContext`(範圍大很多的裁圖)——範圍變大了,
    /// 縮放目標不跟著放大的話,目標文字反而會比緊裁版本更模糊。
    private static let retryVisionLongEdge: CGFloat = 1024

    /// 整頁一次呼叫的生成參數。輸出比逐塊長很多(N 個區塊 × 3 行),額度要放大。
    ///
    /// 溫度沿用 0.2:裝機證據顯示 0.7 對這顆 4-bit 模型是**加重**卡迴圈而不是緩解,
    /// 而且這一輪刻意只改「模型看到多大範圍的圖」這一個變因——同時動多個變因正是
    /// 前面八輪查不出根因的原因。
    private let pageGenerateParameters = GenerateParameters(
        maxTokens: 512,
        temperature: 0.2
    )

    // MARK: - ImageTranslationEngine

    func translateRegion(
        _ region: CGImage,
        widerContext: CGImage?,
        from source: String,
        to target: String
    ) async throws -> ImageRegionTranslation {
        let sourceName = try LanguageNames.name(for: source)
        let targetName = try LanguageNames.name(for: target)
        let container = try await ensureLoaded()
        let prompt = Self.makePrompt(source: sourceName, target: targetName)

        let raw = try await Self.generateOne(
            image: region, prompt: prompt, container: container,
            parameters: generateParameters, resizeLongEdge: Self.visionLongEdge)

        // 重試的判斷依據改成「解析完之後救不救得回來」,不是「原始輸出有沒有重複」
        // ——重複但收斂後仍然是好譯文的情況(例如「呀啊啊啊…」)現在會被救回來,
        // 那種不需要、也不應該再花一次推理去重試。
        let firstAttempt = Self.parse(raw)

        // 真正救不回來的才重試。裝機實測發現同樣的模型透過 Locally AI 看整張圖能
        // 正確讀出這些字,但我們裁太緊、只給孤立的一小塊字時會卡生成迴圈——所以
        // retry 改用範圍大很多的裁圖(涵蓋整個對話框/分鏡),搭配更大的縮放目標
        // 補償變大的範圍,而不是繼續在同一張緊裁圖上換 prompt/溫度。
        if firstAttempt.translatedText == Self.failureMessage {
            let retryRaw = try await Self.generateOne(
                image: widerContext ?? region,
                prompt: Self.makeRetryPrompt(target: targetName),
                container: container,
                parameters: retryParameters,
                resizeLongEdge: Self.retryVisionLongEdge)
            var result = Self.parse(retryRaw)
            result.usedWiderContextRetry = true
            result.firstAttemptRawOutput = raw
            // 重試也救不回來時,如果第一次至少讀到了原文,保留它——除錯清單上
            // 「讀對但翻不出來」跟「連讀都讀不出來」是兩種完全不同的失敗,要分得出來。
            if result.recognizedText.isEmpty { result.recognizedText = firstAttempt.recognizedText }
            return result
        }

        return firstAttempt
    }

    /// 整頁一次讀完(見 `ImageTranslationEngine.translatePage` 的說明)。
    func translatePage(
        _ page: CGImage,
        expectedBlockCount: Int,
        from source: String,
        to target: String
    ) async throws -> ImagePageTranslation? {
        let sourceName = try LanguageNames.name(for: source)
        let targetName = try LanguageNames.name(for: target)
        let container = try await ensureLoaded()

        let prompt = Self.makePagePrompt(source: sourceName, target: targetName)

        var processing = UserInput.Processing()
        processing.resize = Self.pageResizeTarget(
            pixelSize: CGSize(width: page.width, height: page.height))
        let userInput = UserInput(
            chat: [.user(prompt, images: [.ciImage(CIImage(cgImage: page))])],
            processing: processing
        )

        let lmInput = try await container.prepare(input: userInput)
        let stream = try await container.generate(input: lmInput, parameters: pageGenerateParameters)

        // ⚠️ 這個 for-await 迴圈刻意留在 @MainActor 方法裡,不抽成 nonisolated static:
        // 迴圈本體只是字串累加(真正的推理跑在 ModelContainer 那個 actor 裡),留在
        // 這裡就能直接讀寫 self 的狀態,不需要任何跨 isolation 的閃避動作——先前兩次
        // 編譯失敗都是踩在「nonisolated static 呼叫 MainActor-isolated static」上。
        var raw = ""
        for await event in stream {
            if let chunk = event.chunk { raw += chunk }
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = PageOutputParser.parse(
            trimmed, maxItems: Self.pageItemLimit(expectedBlockCount: expectedBlockCount))
        return ImagePageTranslation(items: items, rawOutput: trimmed)
    }

    /// 呼叫端跑完整頁之後呼叫,把 Metal buffer cache 還回去。
    /// 不要每塊都叫——那會逼 MLX 每次重新配置緩衝區,反而更慢。
    func finishPage() {
        MLX.Memory.clearCache()
    }

    /// 一頁最多解析幾個項目,防止模型無限列下去。取 max 保底,避免 Vision 只框到
    /// 一兩塊時把上限壓得太死。
    private nonisolated static func pageItemLimit(expectedBlockCount: Int) -> Int {
        max(12, expectedBlockCount * 3)
    }

    /// 整頁送進 VLM 前的縮放目標。
    ///
    /// ⚠️ `MediaProcessing.apply()` 用 `bestFitScale = min(tw/W, th/H)`,所以傳
    /// **非正方形**目標不是沒意義的——那等於同時表達「寬度 fit 到 tw」與「高度上限
    /// th」。正方形只是「長邊 fit 到 N」這個特例。一般漫畫頁用正方形就好;條漫那種
    /// 超長頁用正方形會因為長邊 fit 而把寬度壓到剩幾百像素、字整個糊掉,要改成
    /// 「寬度 fit + 高度上限」。
    ///
    /// 1024 的依據:`sample-es.jpg` 是 589×1145,長邊 fit 1024 → 527×1024,只縮
    /// 0.89 倍,幾乎等於原生解析度(Vision 在原生 589 寬就抓得到框,解析度從來不是
    /// 這次失敗的瓶頸)。視覺 token 量約 (527/32)×(1024/32) ≈ 530,比現在四次逐塊
    /// 呼叫的總和**還便宜**。
    private nonisolated static func pageResizeTarget(pixelSize: CGSize) -> CGSize {
        let aspect = pixelSize.height / max(pixelSize.width, 1)
        if aspect <= 2.0 { return CGSize(width: 1024, height: 1024) }
        return CGSize(width: 1024, height: 3072)
    }

    /// 整頁 prompt。
    ///
    /// 沿用模型已經證明會正確輸出的 `ORIGINAL:`/`TRANSLATION:` 兩行,並保留已驗證的
    /// ORIGINAL→TRANSLATION 順序(第六輪實測證明對調是負分,連原本翻對的句子都會壞)。
    ///
    /// ⚠️ 裝機實測(第九輪,展開「整頁原始輸出」才看到):舊版 prompt 要求模型自己
    /// 估計「大約幾塊文字」、再輸出自己遞增生成的 `BLOCK n` 編號,結果整頁輸出從頭到
    /// 尾就是 `BLOCK 0 0 0 0 0 0...`——連第一塊的 `ORIGINAL:` 都沒寫到,卡在「要不要
    /// 寫編號」這個結構層面,根本還沒開始讀圖。這代表舊版 prompt 的複合式指令(估算
    /// 數量 + 排序 + 每塊兩步驟 + 三條規則 + 自己生成編號)本身就超出這顆 4-bit 小
    /// 模型的指令遵循能力,是比「難字卡迴圈」更早發生的卡點,跟這個功能真正要驗證的
    /// 假設(模型看到多大範圍的圖能不能讀懂難字)完全是不同的變因。
    /// → 這版拿掉「roughly N text areas」的數量提示與 `BLOCK n` 自生成編號,只留下
    /// 純粹重複的 `ORIGINAL:`/`TRANSLATION:` 兩行——`PageOutputParser` 本來就設計成
    /// 沒有 `BLOCK` 行也解析得出來(遇到第二個 `ORIGINAL:` 就隱含換下一項),不用動
    /// 解析邏輯。目的是把「prompt 結構複雜度」這個新變因跟「上下文範圍」主假設分開,
    /// 只留下兩條已經證實對防卡迴圈有效的硬規則:
    /// 1. 「同一個字母不准連續超過 4 次」放在獨立的 Rules 區塊當**硬規則**,不是埋在
    ///    步驟裡的軟要求——第五輪證明軟措辭沒有用。
    /// 2. 「太難讀就寫 `ORIGINAL: ?`,不要停在難的那個」給一個明確的逃生口:卡迴圈的
    ///    根源就是重複字母沒有自然的停止點。
    ///
    /// ⚠️ 裝機實測(拿掉 BLOCK 編號後這輪):結構卡點解決了,模型真的開始讀圖,
    /// `ORIGINAL` 行也確實遵守「不准連續超過 4 次」——但同一條規則對 `TRANSLATION`
    /// 行完全沒有約束力,翻譯難字(狀聲詞)時卡進「啊啊啊啊…」的重複迴圈,燒光整頁
    /// 512 token 額度,後面的區塊完全沒機會被列出來。
    ///
    /// ⚠️ 裝機實測(加長 TRANSLATION 規則後這輪,**可重現兩次**):結果不是翻譯卡
    /// 重複,而是整段把 prompt 的說明文字(含 placeholder 括號內容、Rules 清單、
    /// 結尾的 Output 那句)幾乎一字不差複誦回來,連讀圖都沒發生。比對三輪的
    /// prompt 長度與結果——8/31 原版(最長:數量提示+BLOCK 編號+兩步驟)卡在結構
    /// 層面;拿掉編號那版(較短)有讀圖但翻譯卡重複;這版把 Rules 拉長、
    /// placeholder 塞進整段說明文字(又變長)反而整段照抄——長度/指令量往上,結果
    /// 往下,三輪一致。**根因收斂到「prompt 總指令量超出這顆 4-bit 小模型的負荷」,
    /// 不是任何單一措辭的問題**。
    /// → 這版重新對齊已驗證穩定的逐塊 prompt(`makePrompt`)的結構:語意說明
    /// (標點、不修正成真實單字、狀聲詞要音譯)放在 Step 1/Step 2 的敘述句裡,
    /// 放在句子裡的說明性文字對模型來說是「要遵守的指示」;放進 `<...>` 括號的
    /// placeholder **必須維持極短**(`<the text you read>` 這種程度),那才是模型
    /// 真正要模仿的「輸出範例格式」,兩者不能混在一起,混在一起會讓模型分不清
    /// 「這是指示」還是「這是我該寫的內容」。同時把三條 TRANSLATION 相關規則合併回
    /// 一條,整體字數盡量貼近「拿掉編號那版」(目前為止長度最短、進展最多的版本),
    /// 不要在別處把長度加回去。
    ///
    /// **刻意不做**:把 Vision 的 OCR 文字當提示塞進 prompt(那樣對位會變得很簡單)。
    /// 那會重新引入混合式架構要避開的污染——模型會錨定在 `¡LIWA! ¡¡LWAA!!` 上複製
    /// Vision 的錯誤,正是先前翻出「離哇」的成因。Vision 文字只在事後當對位訊號。
    private nonisolated static func makePagePrompt(source: String, target: String) -> String {
        """
        This is a full page from a comic book. All the text on it is written in \
        \(source), in a stylised hand-lettered bold font. Some of it is dialogue in \
        speech balloons, some of it is shouting or a sound effect drawn across the artwork.

        For every piece of \(source) text on the page, in reading order (top to bottom, \
        and for text at the same height, left to right):
        Step 1. Read the text as it is drawn. Keep punctuation and inverted marks (¡ ¿). \
        Do not correct it into a real word — it may be a scream or a sound effect rather \
        than a word.
        Step 2. Translate it into \(target). If it is a sound effect or a scream, \
        transliterate the sound into \(target) instead of translating its literal meaning.

        Rules:
        - Never write the same letter or character more than 4 times in a row, in ANY \
        line, including TRANSLATION — a scream must be a short burst like "啊啊啊", not a \
        long string, and kept under about 15 characters.
        - If a text area is too hard to read, write "ORIGINAL: ?" and still give your best \
        TRANSLATION, then move on to the next one. Never stop on a hard one.
        - Do not describe the artwork, the characters or the panels. Text only.

        For each text area write exactly:
        ORIGINAL: <the text you read>
        TRANSLATION: <the \(target) text>

        Output these pairs one after another, nothing else — no numbering, no explanation, \
        no quotes. Stop once every text area on the page is listed.
        """
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
    /// 使用者看到的翻譯結果),retry 只要求一件事:直接給翻譯,不要求對照原文。
    /// 這次搭配的圖也換成範圍大很多的裁圖(見 `translateRegion`),所以額外提醒
    /// 模型只翻譯圖中「那句話」,不要連分鏡裡其他文字或畫面內容一起講。
    ///
    /// ⚠️ 2026-09-02:原本這段寫死「這裡一定有一聲喊叫,給音譯」——這個假設是
    /// 針對 `Qwen3-VL-4B` 當初「難字才會觸發 retry」設計的。裝機實測換成
    /// `Qwen2.5-VL-3B` 後發現:這顆模型連普通句子(`ERES RUIDOSO...`,一句話,
    /// 不是喊叫)都常常在主要路線判定失敗、觸發 retry,retry 卻只會問「音譯那聲
    /// 喊叫」,對正常句子文不對題,吐出跟原文完全對不上的通用喊叫音譯。改成
    /// 「可能是普通句子、也可能是喊叫,兩種都給合理翻譯」,不預設一定是喊叫——
    /// 仍然保留「如果是喊叫就音譯」這條指示,不影響 `Qwen3-VL-4B` 原本靠這段
    /// prompt 救回來的難字案例(那類案例的圖片內容本身就是喊叫,模型看得出來)。
    private static func makeRetryPrompt(target: String) -> String {
        """
        This image is a panel from a comic page, shown with extra surrounding context. \
        Somewhere in it is a piece of dialogue or a sound effect written in a stylised \
        hand-lettered bold font. It may be an ordinary sentence, or it may be a shout \
        with many repeated letters (for example a scream).

        Give a short, natural \(target) translation of just that text (not any other \
        text or the scene itself). If it is a shout or sound effect, transliterate the \
        sound instead of translating its literal meaning, and keep any repeated sound \
        short (2-4 repeats is enough) — do not try to match the exact number of repeats \
        in the image.

        Reply with exactly one line and nothing else, no explanation, no quotes:
        TRANSLATION: <the \(target) text>
        """
    }

    // MARK: - 生成

    private nonisolated static func generateOne(
        image: CGImage,
        prompt: String,
        container: ModelContainer,
        parameters: GenerateParameters,
        resizeLongEdge: CGFloat
    ) async throws -> String {
        // UserInput.Image 只有 .ciImage/.url/.array 三種 case,沒有 .uiImage,
        // 所以直接從 CGImage 包 CIImage。
        let ciImage = CIImage(cgImage: image)

        var processing = UserInput.Processing()
        processing.resize = CGSize(width: resizeLongEdge, height: resizeLongEdge)

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
    /// 生成失敗時顯示的訊息。也當成「這次要不要重試」的判斷依據。
    static let failureMessage = "[生成失敗:輸出異常重複]"

    nonisolated static func parse(_ raw: String) -> ImageRegionTranslation {
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

        // ⚠️ 2026-09-02 裝機實測(換成 Qwen2.5-VL-3B 才暴露):上面逐行比對只認
        // 「行首」的 ORIGINAL:/TRANSLATION:,是照 Qwen3-VL-4B 穩定輸出兩行的
        // 習慣寫的。Qwen2.5-VL-3B 有時候會把兩者擠在**同一行**、中間沒有換行
        // (例如 `ORIGINAL: YA BASTA...TRANSLATION: ya basta...`),這種情況整行
        // 會被 `ORIGINAL:` 那個 anchored 比對整段吃掉,`translated` 永遠抓不到,
        // 被誤判「生成失敗」觸發 retry——而 retry 的 prompt 是寫死問「音譯那聲
        // 喊叫」,不管原文是什麼都會回一個通用喊叫音譯,導致好幾個完全不同的
        // 原文最後都疊出同一句譯文。修法:`original` 裡如果混進了 `TRANSLATION:`
        // 標記,從那裡切開,前半段才是真正的原文、後半段是譯文。
        if translated.isEmpty, let r = original.range(of: "TRANSLATION:", options: .caseInsensitive) {
            translated = String(original[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            original = String(original[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        // ⚠️ 裝機實測(第九輪)抓到的關鍵事實:模型有時候**讀對也翻對了**,只是重複
        // 次數失控——底部吼叫聲那塊輸出的是 `TRANSLATION: 呀啊啊啊…(共 180 字)`。
        // 「呀啊啊啊」本來就是合格的漫畫吼叫聲譯文,舊版卻因為整段命中退化偵測就把
        // 整項丟掉、顯示失敗訊息,等於把好結果當垃圾扔。改成先收斂重複次數再判斷。
        if PageOutputParser.isDegenerateLine(translated) {
            translated = PageOutputParser.collapseRepeats(translated)
        }
        original = PageOutputParser.collapseRepeats(original)

        // ⚠️ 裝機實測發現的 bug:這個 fallback 原本不管 `original` 有沒有解析到值,
        // 只要 `translated` 是空的就把「整段原始輸出(還包含 `ORIGINAL:` 這個標籤
        // 字樣)」當成譯文候補。難字卡在複誦原文階段、只寫出 `ORIGINAL: ¡¡¡¡¡¡...`
        // 完全沒寫到 `TRANSLATION:` 的案例,`ORIGINAL` 這幾個字母讓下面的
        // `hasUsableContent` 誤判「有內容」,導致函式不回傳 `failureMessage`——
        // 寬裁圖 retry(靠比對 `translatedText == failureMessage` 觸發)因此從來沒有
        // 機會執行。只有在 `original` 也是空的(模型整段沒照格式、裸寫一般文字)才
        // 適合把整段原始輸出當譯文救回來;`original` 有值但 `translated` 沒有,代表
        // 模型卡在讀原文階段,`translated` 要保持空字串,才能讓下面的
        // `hasUsableContent` 正確判定失敗、真正觸發 retry。
        if translated.isEmpty && original.isEmpty {
            let fallback = raw
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            translated = PageOutputParser.isDegenerateLine(fallback)
                ? PageOutputParser.collapseRepeats(fallback)
                : fallback
        }

        // 收斂之後還是沒有任何文字內容(例如整段只剩一堆 `¡` 或 `!!!`)才算真的失敗。
        guard PageOutputParser.hasUsableContent(translated) else {
            return ImageRegionTranslation(
                recognizedText: original, translatedText: failureMessage, rawOutput: raw)
        }
        return ImageRegionTranslation(recognizedText: original, translatedText: translated, rawOutput: raw)
    }

    // 註:原本這裡有一份 `isDegenerateOutput`(整段判斷、命中就整個丟掉)。
    // 現在退化判斷統一由 `PageOutputParser.isDegenerateLine` 負責(逐行判斷),
    // 而且命中之後是先 `collapseRepeats` 收斂重複次數搶救,不是直接丟掉——
    // 裝機實測證明被丟掉的輸出裡有讀對也翻對的好結果。

    // MARK: - 載入(含下載)

    @discardableResult
    func ensureLoaded() async throws -> ModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }

        // ⚠️ 2026-09-02:`LocalModelStore.makeHubClient()` 已經改回一般
        // session(背景 session 那次改動裝機直接崩潰,見該檔案的說明),
        // 下載不再保證撐過切背景。這裡只做能力範圍內的緩解——用
        // `beginBackgroundTask` 換一點點切背景瞬間的額外執行時間,不是解法,
        // 只是讓「使用者手滑切一下背景又切回來」不會立刻整個中斷。
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "vlm-model-download") {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        defer {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }

        // VLM 權重 3.1GB(比 TranslateGemma 的 2.2GB 大),cache 上限相對壓小一點。
        MLX.Memory.cacheLimit = 128 * 1024 * 1024

        // 在進入 detached task 前先讀一次(MainActor 隔離的 @Published 屬性),
        // 避免 task 內部跨 actor 存取 self.selectedModel。
        let modelOption = selectedModel
        let configuration = modelOption.configuration
        let approximateDownloadBytes = modelOption.approximateDownloadBytes

        let task = Task.detached(priority: .userInitiated) { [weak self] () throws -> ModelContainer in
            // ⚠️ `isModelPresent()` 只檢查「models 目錄有沒有任何東西」,不分是
            // 哪一顆模型——多模型可選之後,切到目前還沒下載過的新模型時,如果
            // 目錄裡已經有另一顆模型,這個提前檢查會被跳過,空間不夠時會晚一點
            // 在 `VLMModelFactory.loadContainer` 內部才失敗(錯誤訊息比較不友善,
            // 但不會靜默損毀資料)。之前只有一顆模型時這不是問題,現在是已知的
            // 小缺口,還沒修。
            if !LocalModelStore.isModelPresent(),
               let available = LocalModelStore.availableBytesForImportantUsage(),
               available < approximateDownloadBytes + 500_000_000 {
                throw LocalLLMError.insufficientDiskSpace(
                    needed: approximateDownloadBytes, available: available)
            }

            let downloader = HubSnapshotDownloader(try LocalModelStore.makeHubClient(purpose: "vlm"))
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
                parameters: GenerateParameters(maxTokens: 2, temperature: 0.0),
                resizeLongEdge: Self.visionLongEdge
            )

            await MainActor.run {
                self?.phase = .ready
                self?.refreshDownloadedModels()
            }
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

    /// 切換要用的 VLM 模型。一定要先卸載目前的模型才能換 `selectedModel`——
    /// `ensureLoaded()` 一開始就會回傳已快取的 `container`,不先卸載的話換了
    /// 選項也不會真的載入新模型,呼叫端不用自己記得順序。
    func changeModel(to option: VLMModelOption) {
        guard option != selectedModel else { return }
        unload()
        selectedModel = option
    }

    /// 掃一次本機快取,更新每個選項「有沒有下載過」。呼叫端(ContentView)在
    /// app 啟動時呼叫一次,`ensureLoaded()` 下載/載入完成時也會自動呼叫。
    func refreshDownloadedModels() {
        downloadedModels = Set(
            VLMModelOption.allCases.filter { LocalModelStore.isModelDownloaded($0.configuration) })
    }

    /// 移除某個選項在本機的權重檔。如果正好是目前載入中的那顆,先 `unload()`
    /// 再刪,避免砍掉還在使用中的檔案。
    func removeDownload(of option: VLMModelOption) {
        if option == selectedModel { unload() }
        try? LocalModelStore.removeModel(option.configuration)
        refreshDownloadedModels()
    }
}

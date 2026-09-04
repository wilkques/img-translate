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
        // ⚠️ 2026-09-03:`Qwen3-VL-2B` 已從選單移除(Cyril 要求拿掉,選單
        // 精簡)——沒有裝機驗證過壞掉,只是不再提供這個選項,不是像 Gemma 4/
        // LFM2.5 那樣確認壞掉不能用。
        /// 2026-09-02:跟 `Gemma 4` 不是同一代架構——`Gemma 4` 掛在
        /// `mlx-swift-lm` 3.31.4 是因為它「共享 KV 注意力」這個新架構特徵的
        /// 載入程式碼還沒補上,`Gemma 3` 是上一代架構,沒有這個問題。查證
        /// 2026 年評測顯示 `Gemma 3` 在翻譯/多語言任務上比 `Qwen3-VL` 系列強
        /// (涵蓋 140+ 語言),用來對照 `Qwen2.5-VL-3B` 常見的「普通句子照抄
        /// 不翻」這個弱點。體積跟 `Qwen3-VL-4B` 同級,連續閱讀多張圖大機率
        /// 一樣會撞記憶體上限——這是品質比較用的選項,不是穩定性解法。
        case gemma3_4B = "Gemma 3 4B"
        // ⚠️ 2026-09-03:`Gemma 4 E2B`/`E4B` 已從選單移除,不要再加回來。
        //
        // 兩顆都確認下載成功但**載入失敗**(`VLMRegistry.gemma4_E2B_it_4bit`/
        // `gemma4_E4B_it_4bit`,已裝機驗證存在)——根因是 `mlx-swift-lm`
        // 3.31.4 對 Gemma 4 架構「共享 KV 尾端層」的 k_norm 形狀處理有 bug
        // (上游已知,見 `ml-explore/mlx-lm` issue #1210、`ml-explore/
        // mlx-swift-lm` issue #282),不是我們的程式碼能修的。2026-09-03
        // 裝機再測 E4B(檔案已經下載過,這次是重新載入快取檔案觸發的):
        // 這次沒有乾淨丟出可捕捉的錯誤,而是整個卡住不動(「下載 0%」卡死、
        // 後面排隊的翻譯工作跟著卡住),比先前紀錄的「載入失敗訊息」更糟。
        // 跟 `Gemma 3 4B` 是完全不同世代架構,不要混淆。
        //
        // 之後要重新評估的前提:`mlx-swift-lm` 升級到修掉這個 k_norm bug 的
        // 版本,不是換 repo id 或量化版本能解決的。
        // ⚠️ 整個 `LFM2.5-VL` 系列也已移除,不要再加回來。
        //
        // 兩次裝機都是同一種閃退(`EXC_BREAKPOINT`/`SIGTRAP` →
        // `_assertionFailure`,同一條呼叫鏈):
        // 1. 09-02 `LFM2.5-VL-3B (4bit)` —— 事後查證那個 repo id 是我照命名
        //    慣例猜的、根本不存在,當時以為崩潰是 404 造成的
        // 2. 09-03 `LFM2.5-VL-3B (8bit)` —— **這顆 repo 確認存在**,而且新版
        //    已經有 `verifyRepositoryExists` 會先擋 404,還是崩在同一個地方
        //
        // 第 2 次排除了「repo 不存在」這個解釋,結論收斂到:**釘住的
        // `mlx-swift-lm` 3.31.4 裡的 `LFM2VL.swift` 是針對上一代 `LFM2-VL`
        // 寫的,載不動 `LFM2.5` 這代骨幹**。跟 `Gemma 4` 是同一類上游還沒跟上
        // 的問題,差別在 `Gemma 4` 丟出可捕捉的 error(畫面顯示載入失敗),
        // `LFM2.5` 直接 trap ——接不住、整個 process 死。
        //
        // `LFM2.5-VL-1.6B`(4bit/8bit,repo 都確認存在)是同一代骨幹,幾乎
        // 肯定一樣崩,不值得再花一次下載+閃退去驗證,一併移除。
        //
        // 之後要重新評估的前提:`mlx-swift-lm` 升級到有支援 `LFM2.5` 的版本
        // (查 `LFM2VL.swift` 的更新紀錄),不是換 repo id 或量化版本能解決的。

        var id: String { rawValue }

        /// ⚠️ `gemma4_E2B_it_4bit`/`gemma4_E4B_it_4bit`/`gemma3_4B_qat_4bit`
        /// 都是透過網路搜尋找到的 `VLMRegistry` preset 名稱,沒有管道直接讀到
        /// 專案釘住版本(`mlx-swift-lm` 3.31.4)的原始碼逐字確認拼字——如果
        /// 編譯錯誤說找不到這個屬性,去對照該 tag 的 `VLMModelFactory.swift`
        /// 修正,不是程式邏輯的問題。
        var configuration: ModelConfiguration {
            switch self {
            case .qwen3VL4B: return VLMRegistry.qwen3VL4BInstruct4Bit
            case .qwen2_5VL3B: return VLMRegistry.qwen2_5VL3BInstruct4Bit
            case .gemma3_4B: return VLMRegistry.gemma3_4B_qat_4bit
            }
        }

        /// 顯示用的下載大小估計,只影響進度條準不準,不影響功能。Gemma 系列
        /// 幾顆是用有效參數量推算的粗估值(MatFormer 架構打包方式可能跟
        /// dense 4-bit 不同),第一次真的下載完後應該回來對實際大小校正。
        var approximateDownloadBytes: Int64 {
            switch self {
            case .qwen3VL4B: return 3_200_000_000    // safetensors 3.09GB + tokenizer/config
            case .qwen2_5VL3B: return 2_000_000_000  // 待確認
            case .gemma3_4B: return 3_000_000_000    // 待確認,抄 qwen3VL4B 起手值
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
        //
        // ⚠️ 2026-09-03:裝機實測發現「卡進重複迴圈」不是只有狀聲詞才會觸發,
        // 一般但比較長/複雜的敘述句(例如「那兩人是有關係的」這種完整句子)
        // 偶爾也會讓 3B 模型卡住——而且卡不卡住帶隨機性(`temperature: 0.2`
        // 不是純貪婪解碼),同一句話重跑不一定卡在同個地方。原本只重試一次,
        // 運氣不好一次就放棄。改成**最多重試 `maxWiderContextRetries` 次**,
        // 中途只要有一次成功就停,把「要不要再試一次」這個決定從使用者手動
        // 按重試按鈕,搬進程式自己做——次數選 2(共 3 次嘗試:1 次主要 +
        // 2 次寬裁圖重試),再往上加會讓卡住到底的難句拖更久才顯示失敗,划不來。
        if firstAttempt.translatedText == Self.failureMessage {
            let maxWiderContextRetries = 2
            var lastResult = firstAttempt
            for _ in 0..<maxWiderContextRetries {
                let retryRaw = try await Self.generateOne(
                    image: widerContext ?? region,
                    prompt: Self.makeRetryPrompt(target: targetName),
                    container: container,
                    parameters: retryParameters,
                    resizeLongEdge: Self.retryVisionLongEdge)
                var result = Self.parse(retryRaw)
                result.usedWiderContextRetry = true
                result.firstAttemptRawOutput = raw
                // 重試也救不回來時,如果第一次至少讀到了原文,保留它——除錯清單
                // 上「讀對但翻不出來」跟「連讀都讀不出來」是兩種完全不同的失敗,
                // 要分得出來。
                if result.recognizedText.isEmpty { result.recognizedText = firstAttempt.recognizedText }
                lastResult = result
                if result.translatedText != Self.failureMessage { return result }
            }
            return lastResult
        }

        return firstAttempt
    }

    /// ⚠️ 2026-09-03:**實驗性路線**,測試「Vision OCR 準確率夠高的話,直接
    /// 翻文字比繞去讀裁圖快很多」這個假設(見 `notes/2026-09-03.md`)。跟
    /// `translateRegion`(讀裁圖)是兩條完全獨立的路線,互不影響,呼叫端
    /// (`TranslationRequestCoordinator`)用一個開關選擇要走哪條。
    ///
    /// 這是同一個已載入的 VLM container(Qwen2.5-VL-3B),不是另外接
    /// `LocalLLMTranslationEngine`(TranslateGemma)那顆獨立模型——兩顆模型
    /// 同時載入記憶體太緊,先前已經因為這個理由拿掉雙引擎並存的設計,不要
    /// 重蹈覆轍。呼叫方式是同一個 `UserInput`/`Chat.Message.user`,只是
    /// `images:` 傳空陣列——這顆模型本身是通用 instruct VLM,純文字對話
    /// 理論上是最基本的使用情境,但**這個專案裡從沒有人這樣呼叫過**,是否
    /// 真的支援、會不會在轉圖片 token 的路徑上出問題,只能裝機驗證確認。
    ///
    /// 刻意**沒有**重試機制(跟 `translateRegion` 不同)——這輪只是驗證基本
    /// 假設成不成立,先看單次呼叫的品質/速度,不要一次疊加太多變因。
    ///
    /// ⚠️ 2026-09-03:`context` 是這輪新加的——每個對話框原本是完全獨立的
    /// 一次呼叫,模型不知道同一話裡其他對話框翻了什麼,人名音譯、代名詞、
    /// 語氣容易每格不一致。呼叫端(`TranslationRequestCoordinator`)會傳進
    /// 最近幾筆「原文→譯文」當參考,幫模型維持一致性。純文字模式才加這個
    /// ——沒有圖片 token 的負擔,多幾行文字提示成本很低;`translateRegion`
    /// (讀圖路線)那兩份已經裝機驗證很多輪的 prompt 不動,风险太高不值得。
    /// ⚠️ 2026-09-04:回傳型別從單一 `String` 改成帶 `rawOutput` 的 tuple——
    /// 裝機實測發現 `Qwen3-VL-4B` 有時把標籤縮寫成「TRANSLA:」而不是完整的
    /// 「TRANSLATION:」,導致解析失敗、把整段原始輸出(含標籤字面)直接當
    /// 譯文顯示。這種「看起來是譯文字串,其實混進不該有的內容」的狀況不容易
    /// 只靠解析後的結果診斷,呼叫端需要原始輸出才能在除錯清單裡對照,不然
    /// 每次都是在沒有證據的情況下猜 prompt/生成參數要怎麼調。
    func translateText(
        _ text: String, from source: String, to target: String,
        context: [(original: String, translated: String)] = []
    ) async throws -> (translated: String, rawOutput: String) {
        let sourceName = try LanguageNames.name(for: source)
        let targetName = try LanguageNames.name(for: target)
        let container = try await ensureLoaded()
        let prompt = Self.makeTextOnlyPrompt(
            source: sourceName, target: targetName, text: text, context: context)

        let userInput = UserInput(chat: [.user(prompt, images: [])])
        let lmInput = try await container.prepare(input: userInput)
        let stream = try await container.generate(input: lmInput, parameters: textOnlyGenerateParameters)

        var raw = ""
        for await event in stream {
            if let chunk = event.chunk { raw += chunk }
        }
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (Self.parseTextOnly(trimmedRaw, originalText: text), trimmedRaw)
    }

    /// 比 `generateParameters` 小很多——沒有圖片 token、沒有「先讀原文」這個
    /// 步驟,單行翻譯結果理論上不需要 150 token 額度。
    private let textOnlyGenerateParameters = GenerateParameters(
        maxTokens: 60,
        temperature: 0.2
    )

    /// ⚠️ 2026-09-03 裝機驗證(第一版 prompt)抓到三個問題:
    /// 1. 好幾筆譯文被套上實體角括號(`<巴別了>`、`<你很吵闹......>`)——原本的
    ///    範例格式 `TRANSLATION: <the target text>` 用角括號當佔位符號,模型
    ///    把角括號本身也照抄進輸出裡,不是當成「這裡填文字」的記號。改成給一個
    ///    **具體範例**(真的示範一句話怎麼翻)取代抽象佔位符號,不用角括號。
    /// 2. 有一筆(`NA MLGYEOM`)直接用英文解釋「The Traditional Chinese text
    ///    is: 貓咪叫聲」,完全沒有照格式回答——加強「不要解釋、不要描述」的
    ///    措辭。
    /// 3. 有一筆(`¡UWA! ¡¡UWAA!! IIIUWAAA!!!`)原封不動照抄原文,沒有真的
    ///    翻譯或音譯——明講「一定要給出真正的翻譯,不能原封不動照抄」。
    /// 這三點都是同一份全新 prompt 的第一次調整,不是動 `makePrompt`/
    /// `makeRetryPrompt` 那兩份已經裝機驗證很多輪的既有 prompt。
    ///
    /// ⚠️ 2026-09-03:加了 `context`(最近幾筆已翻過的原文→譯文)幫模型維持
    /// 人名/語氣一致性。刻意放在提示**最前面**、跟主要指令用空行隔開,且明講
    /// 「僅供參考、不是要翻譯的內容」——避免模型把上下文那幾行也當成這次要
    /// 翻譯的文字混進輸出裡。`context` 是空陣列時這段完全不出現,不影響原本
    /// 已經驗證過的行為。
    private static func makeTextOnlyPrompt(
        source: String, target: String, text: String,
        context: [(original: String, translated: String)]
    ) -> String {
        var contextBlock = ""
        if !context.isEmpty {
            let lines = context.map { "\($0.original) => \($0.translated)" }.joined(separator: "\n")
            contextBlock = """
            For reference only (already translated earlier in this same comic chapter, \
            so you can keep character names, tone and pronouns consistent with them — \
            these are NOT the text to translate now):
            \(lines)


            """
        }
        return """
        \(contextBlock)Translate the following \(source) comic dialogue into \(target). You must always \
        give an actual \(target) translation — never leave the text unchanged or just copy \
        the original as your answer, and never explain or describe what the text says. \
        It may be an ordinary sentence, or it may be a shout or sound effect written with \
        repeated letters — if so, transliterate the sound into \(target) instead of \
        translating its literal meaning, and keep any repeated sound short (2-4 repeats is \
        enough).

        Text: \(text)

        Reply with exactly one line, nothing else: the word TRANSLATION, a colon, a space, \
        then only the \(target) text itself — no angle brackets, no quotes, no explanation, \
        and do not repeat or label the original \(source) text before or after your answer. \
        For example, if the text was "HOLA" and the target language was Chinese, the correct \
        whole reply is:
        TRANSLATION: 你好
        """
    }

    /// 跟 `parse(_:)` 共用同一套退化偵測/收斂邏輯(`PageOutputParser`),但
    /// 只解析單一 `TRANSLATION:` 行——這條路線沒有 `ORIGINAL:`,原文本來就是
    /// 呼叫端傳進來的 Vision OCR 文字,不需要模型再讀一次。
    ///
    /// ⚠️ 2026-09-04:標籤比對原本要求精確比對完整單字「TRANSLATION:」,裝機
    /// 實測 `Qwen3-VL-4B` 有時把它縮寫成「TRANSLA:」——完全比對不到,整段
    /// 原始輸出(含「TRANSLA:」字面)就被當成譯文直接顯示出來。改成「找該行
    /// 第一個冒號,冒號前的字只要以 TRANSLA 開頭就算數」,不要求完整單字,
    /// 這樣「TRANSLATION:」「TRANSLA:」「TRANSLATE:」都認得出來。
    private nonisolated static func parseTextOnly(_ raw: String, originalText: String) -> String {
        var translated = ""
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIndex = trimmed.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let label = trimmed[..<colonIndex].trimmingCharacters(in: .whitespaces).uppercased()
            guard label.hasPrefix("TRANSLA") else { continue }
            translated = String(trimmed[trimmed.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
            break
        }
        if translated.isEmpty {
            translated = raw.replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 防呆:即使 prompt 已經改成具體範例、明講不要加角括號,模型偶爾還是
        // 可能把舊習慣的佔位符號格式帶進來(裝機實測案例:"<巴別了>"、
        // "<你很吵闹......>")。這裡多一層保險去掉包住整段文字的角括號,
        // 不影響本來就沒有括號的正常輸出。
        if translated.hasPrefix("<"), translated.hasSuffix(">"), translated.count >= 2 {
            translated = String(translated.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
        }
        // 防呆:裝機實測抓到模型把原文本身當標籤加在譯文前面,例如
        // `VAMONOS.` 被翻成「VAMONOS: 我们走。」——懷疑是加了上下文範例
        // (原文 => 譯文的格式)之後,模型模仿那個「兩段並列」的樣子帶進自己
        // 的單行輸出裡。偵測「開頭幾乎等於原文,後面接著冒號/箭頭之類的
        // 分隔符號」就把這段前綴去掉,只留真正的譯文。
        if let stripped = Self.stripEchoedOriginalPrefix(from: translated, original: originalText) {
            translated = stripped
        }
        if PageOutputParser.isDegenerateLine(translated) {
            translated = PageOutputParser.collapseRepeats(translated)
        }
        guard PageOutputParser.hasUsableContent(translated) else { return failureMessage }
        return translated
    }

    private nonisolated static func stripEchoedOriginalPrefix(from translated: String, original: String) -> String? {
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOriginal.isEmpty else { return nil }
        let candidates = Set([
            trimmedOriginal,
            trimmedOriginal.trimmingCharacters(in: .punctuationCharacters)
        ]).filter { !$0.isEmpty }
        for candidate in candidates {
            for separator in [":", "：", "=>", "->", "—", "-"] {
                let prefix = candidate + separator
                guard translated.count > prefix.count,
                      translated.lowercased().hasPrefix(prefix.lowercased()) else { continue }
                let rest = String(translated.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return rest }
            }
        }
        return nil
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
    ///
    /// ⚠️ 2026-09-03:試過加一句「人名也要音譯」(跟現有「狀聲詞要音譯」平行
    /// 的新增指示,不是取代),**裝機實測是負分,已經 revert**——加了那句之後
    /// 四個測試區塊全部退化回「整頁完全對不到、逐塊備援全部吐通用喊叫音譯
    /// 哇哇哇」,連上一輪才剛翻對的 `ERES RUIDOSO` 都一起壞掉,退回到跟最早
    /// 那個 bug 一模一樣的症狀。這再次驗證這份 prompt 對「總指令量」極度敏感
    /// (跟 08-28/08-31 整頁 prompt 那次「拿掉數量提示才解決結構卡死」是同一個
    /// 教訓)——**加任何一句話都要當成一次獨立實驗裝機驗證,不能跟其他改動
    /// 一起送、也不能想當然爾「這句話跟現有邏輯無關就應該安全」**。「人名也要
    /// 翻譯」這個需求本身沒有錯,只是不能用「加長主要 prompt」這個做法達成,
    /// 需要另外想辦法(例如只在 retry 這種本來就簡化過的路徑加,或用後處理
    /// 而非 prompt 指示)。
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
        var usedRawFallback = false
        if translated.isEmpty && original.isEmpty {
            usedRawFallback = true
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

        // ⚠️ 2026-09-03:上面那個「兩者皆空」的 fallback,原本的假設是「模型
        // 可能沒照格式、但裸寫的內容或許是個有效答案,值得搶救」。裝機實測
        // 至今看到的所有案例(`VAMONOS.`、疑似角色名 `NA MUGYEOM`),這個分支
        // 救回來的都是**模型完全沒有嘗試翻譯、原封不動照抄輸入**,不是「忘記
        // 加標籤但翻對了」。Cyril 已經拍板人名也要音譯,代表「輸出等於輸入」
        // 在任何情況下都不是正確答案,原本「可能是專有名詞正確保留」的顧慮
        // 不成立——不再搶救,直接判定失敗,交給 `translateRegion` 既有的
        // 寬裁圖 retry 處理。**這是純邏輯改動,沒有動任何 prompt 文字**,跟
        // 上次「加一句人名指示到 prompt 裡」那次裝機證實負分的做法不是同一
        // 條路,不應該重蹈那次的覆轍(但仍要照方法論獨立裝機驗證,不能省略,
        // 尤其要確認 `YA BASTA`/`ERES RUIDOSO` 這些已經翻對的句子沒有被拖累)。
        if usedRawFallback {
            return ImageRegionTranslation(
                recognizedText: original, translatedText: failureMessage, rawOutput: raw)
        }

        // ⚠️ 2026-09-03 裝機實測抓到的新失敗模式:模型正確讀到一整句
        // (`original` 有完整內容),`translated` 卻只吐出一兩個字(例如單一個
        // 「譯」字)——一整句話不可能合理翻成一兩個字,但這種輸出通過得了上面
        // `hasUsableContent`(畢竟真的有一個字)跟既有的「重複字元卡迴圈」判斷
        // (根本沒有重複),兩層既有的退化偵測都抓不到,直接被當成正常翻譯顯示
        // 出來。加一道「原文夠長、譯文短到不成比例」的判斷,抓到才算失敗觸發
        // retry。門檻只挑最極端的情況(譯文 ≤ 2 字元且原文 ≥ 8 字元),刻意
        // 保守——真正的短句翻譯(狀聲詞收斂後可能只有 2-3 字)不會被這條規則
        // 誤傷,只有「原文很長、譯文短到不合理」這種明顯壞掉的比例才會觸發。
        if translated.count <= 2 && original.count >= 8 {
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

        // ⚠️ 2026-09-02:真正的背景下載目前做不到——`HubClient`
        // (`swift-huggingface`)內部用完成處理常式風格的 API,iOS 禁止在背景
        // `URLSessionConfiguration` 上使用,09-01 那次改動裝機直接崩潰
        // (見 `LocalModelStore.makeHubClient` 的說明),已 revert。
        //
        // 在不動上游的前提下,能做的是**擋掉最常見的中斷來源:螢幕自動鎖定**。
        // 模型動輒 1-3GB,下載期間使用者多半把手機放著不管,螢幕一鎖上前景
        // 執行時間很快就用完、下載跟著斷。下載期間關掉閒置計時器,手機放著
        // 螢幕也不會自己暗掉,配合上面的 `beginBackgroundTask`,實務上涵蓋了
        // 「放著等它下載完」這個主要情境。`defer` 一定要還原,不然 App 之後
        // 整個生命週期螢幕都不會自動關,很耗電。
        let previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled }

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

            // 下載前先確認 repo 真的存在——猜錯的 repo id 會讓底層直接 Swift
            // trap 閃退(接不住),先問一次 API 把它變成看得到的錯誤訊息。
            try await LocalModelStore.verifyRepositoryExists(configuration)

            let downloader = HubSnapshotDownloader(try LocalModelStore.makeHubClient(purpose: "vlm"))
            let tokenizerLoader = HuggingFaceTokenizerLoader()

            await MainActor.run { self?.phase = .downloading(0) }

            // ⚠️ 2026-09-02:上游 `HubClient` 的 `progressHandler` 裝機實測
            // **百分比從頭到尾不會動**(下載本身有在跑,只是沒回報進度)。改成
            // 自己起一個輪詢,定期掃硬碟看模型檔案長多大、除以預估總大小算進度
            // ——不依賴上游行為,不管它回不回報都會動。
            //
            // 幾個刻意的設計:
            // - 上限夾在 0.99:`approximateDownloadBytes` 只是估計值,實際檔案
            //   可能比估的小,不夾住的話會提早顯示 100% 然後卡住,比不動更糟。
            // - 只在 `phase` 還是 `.downloading` 時才寫入:下載完成後主流程會
            //   換成 `.loadingWeights`/`.warmingUp`,輪詢不能把它蓋回去。
            // - `defer` 取消:不管 `loadContainer` 成功、丟錯還是被取消,輪詢
            //   都要停,不能留一個永遠在跑的背景迴圈。
            let progressPoller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled, let self else { break }
                    guard case .downloading = self.phase else { continue }
                    let bytes = LocalModelStore.downloadedBytes(configuration)
                    guard bytes > 0, approximateDownloadBytes > 0 else { continue }
                    let fraction = min(
                        Double(bytes) / Double(approximateDownloadBytes), 0.99)
                    self.phase = .downloading(fraction)
                }
            }
            defer { progressPoller.cancel() }

            // 跟 LLMModelFactory.loadContainer 完全同簽名——HuggingFaceBridge.swift/
            // LocalModelStore.swift 一行都不用改,只是換一個 factory。
            let container = try await VLMModelFactory.shared.loadContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: configuration
            ) { progress in
                // 百分比交給上面的輪詢算,這裡只留「下載完成 → 換成載入權重
                // 階段」這個轉換。兩邊都寫百分比會互相蓋來蓋去,而且上游這個
                // 值實測本來就不可靠。
                guard progress.fractionCompleted >= 1.0 else { return }
                Task { @MainActor in self?.phase = .loadingWeights }
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

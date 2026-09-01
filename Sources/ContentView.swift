import SwiftUI
import UIKit
import Foundation

struct ContentView: View {
    enum EngineKind: String, CaseIterable {
        /// 整頁一次讀完再配回 bbox。新的預設——裝機證據顯示同級模型看整張圖讀得出
        /// 我們一直失敗的狀聲詞,問題出在裁圖太小沒有上下文。
        case visionPage = "整頁VLM"
        /// 現行逐塊裁圖路線,原封不動保留當對照組(同一顆 build 就能切換比較,
        /// 不用再等一次 CI)。
        case visionRegion = "逐塊VLM"
        case text = "文字模型"
    }

    @State private var blocks: [TextBlock] = []
    @State private var cropPreviews: [UUID: UIImage] = [:]
    /// 只有走過寬範圍裁圖重試的區塊才有,用來確認重試實際看到的圖長什麼樣。
    @State private var widerCropPreviews: [UUID: UIImage] = [:]
    @State private var showTranslated = true
    @State private var status = "準備中…"
    @State private var imageSize: CGSize = .zero
    @State private var smokeTestResult = ""
    @State private var engineKind: EngineKind = .visionPage
    /// 整頁路線的模型完整原始輸出。這是本輪最重要的除錯產物,完整顯示不截斷。
    @State private var pageRawOutput = ""
    @State private var pageItemCount = 0

    /// 整頁項目與 Vision 區塊的對位接受門檻(字串相似度)。起手值,等裝機把實際
    /// 分數印出來再校準——分數會顯示在除錯清單每一列上。
    private static let pageMatchThreshold = 0.3
    @StateObject private var localEngine = LocalLLMTranslationEngine()
    @StateObject private var vlmEngine = VLMTranslationEngine()

    private let image: UIImage? = {
        guard let path = Bundle.main.path(forResource: "sample-es", ofType: "jpg"),
              let img = UIImage(contentsOfFile: path) else { return nil }
        return img
    }()

    @State private var sourceLanguage = "es"
    @State private var targetLanguage = "zh-Hant-TW"

    /// 固定清單,對應 `LocalLLMTranslationEngine.languageNameMap`/`LanguageNames` 有映射的語言代碼。
    private let languageOptions: [(code: String, label: String)] = [
        ("es", "西班牙文"),
        ("en", "英文"),
        ("ja", "日文"),
        ("ko", "韓文"),
        ("fr", "法文"),
        ("de", "德文"),
        ("zh-Hans", "簡體中文"),
        ("zh-Hant-TW", "繁體中文(台灣)")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                languagePickers

                enginePicker

                GeometryReader { geo in
                    ZStack {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                        if showTranslated {
                            ForEach(blocks) { block in
                                let rect = CoordinateTransform.viewRect(
                                    forImagePixelRect: block.pixelRect,
                                    imagePixelSize: imageSize,
                                    containerSize: geo.size
                                )
                                BubbleOverlayView(
                                    text: block.translatedText ?? block.visionText, rect: rect)
                            }
                        }
                    }
                }

                Text(status).font(.caption).foregroundStyle(.secondary)

                pageDebugSection

                debugList

                Button(showTranslated ? "顯示原圖" : "顯示疊字翻譯") {
                    showTranslated.toggle()
                }
                .buttonStyle(.borderedProminent)

                mlxSmokeTestSection
            }
            .padding()
            .navigationTitle("ImgTranslate")
            .task(id: "\(sourceLanguage)|\(targetLanguage)|\(engineKind.rawValue)") {
                await runPipeline()
            }
        }
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("翻譯引擎", selection: $engineKind) {
                ForEach(EngineKind.allCases, id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            // 兩個模型不能同時載入(2.2GB+3.1GB 太緊,加推理開銷會逼近/超過
            // LiveContainer 的記憶體上限),切換引擎時把沒在用的那個卸載掉。
            .onChange(of: engineKind) { _, newValue in
                switch newValue {
                case .visionPage, .visionRegion: localEngine.unload()
                case .text: vlmEngine.unload()
                }
            }

            switch engineKind {
            case .text: localEngineStatusLine
            case .visionPage, .visionRegion: vlmEngineStatusLine
            }
        }
    }

    @ViewBuilder
    private var localEngineStatusLine: some View {
        switch localEngine.phase {
        case .idle:
            EmptyView()
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("下載模型中 \(Int(fraction * 100))%(約 2.2GB,首次執行請連 WiFi)")
                    .font(.caption2)
            }
        case .loadingWeights:
            ProgressView { Text("載入模型權重中…").font(.caption2) }
        case .translating(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("本機模型翻譯中 \(done)/\(total)").font(.caption2)
            }
        case .ready:
            Text("本機模型就緒").font(.caption2).foregroundStyle(.secondary)
        case .failed(let message):
            Text("本機模型失敗:\(message)").font(.caption2).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var vlmEngineStatusLine: some View {
        switch vlmEngine.phase {
        case .idle:
            EmptyView()
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("下載視覺模型中 \(Int(fraction * 100))%(約 3.1GB,首次執行請連 WiFi)")
                    .font(.caption2)
            }
        case .loadingWeights:
            ProgressView { Text("載入模型權重中…").font(.caption2) }
        case .warmingUp:
            ProgressView { Text("首次暖機中(編譯 Metal pipeline)…").font(.caption2) }
        case .translating(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("視覺模型讀圖翻譯中 \(done)/\(total)").font(.caption2)
            }
        case .ready:
            Text("視覺模型就緒").font(.caption2).foregroundStyle(.secondary)
        case .failed(let message):
            Text("視覺模型失敗:\(message)").font(.caption2).foregroundStyle(.red)
        }
    }

    private var languagePickers: some View {
        HStack {
            Picker("來源語言", selection: $sourceLanguage) {
                ForEach(languageOptions, id: \.code) { option in
                    Text(option.label).tag(option.code)
                }
            }
            Text("→")
            Picker("目標語言", selection: $targetLanguage) {
                ForEach(languageOptions, id: \.code) { option in
                    Text(option.label).tag(option.code)
                }
            }
        }
        .pickerStyle(.menu)
        .font(.caption)
    }

    /// 依語言代碼組出 Vision 看得懂的 recognitionLanguages 格式(BCP-47)
    private func visionRecognitionLanguage(for code: String) -> String {
        switch code {
        case "es": return "es-ES"
        case "en": return "en-US"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "zh-Hans": return "zh-Hans"
        case "zh-Hant-TW": return "zh-Hant"
        default: return code
        }
    }

    /// Stage 0/1:驗證 Metal/MLX 能不能在 LiveContainer 環境下正常運作,
    /// 不下載任何模型——先確認環境,通過才值得投入接模型。
    private var mlxSmokeTestSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("MLX 自我檢測") { smokeTestResult = MLXSmokeTest.run() }
                .buttonStyle(.bordered)
            if !smokeTestResult.isEmpty {
                Text(smokeTestResult)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    /// 顯示裁圖縮圖 + Vision 辨識原文 + VLM 讀到的原文 + 譯文,方便判斷卡在
    /// 「框抓錯」「裁歪/裁太緊」「VLM 讀錯」「翻錯」哪一步(文字引擎沒有裁圖/VLM
    /// 讀字這兩欄,對應顯示空白)。
    ///
    /// 生成失敗的區塊額外顯示「有沒有走重試、重試看到多寬的圖、兩次生成的原始輸出」
    /// ——先前好幾輪裝機測試,主要路線失敗跟重試也失敗在畫面上長得一模一樣,等於
    /// 沒有資訊可以判斷該往哪個方向修,只能瞎猜 prompt/參數。
    /// 每列預設**收合**,只留「一眼看出這塊翻得對不對」的摘要行(Vision/VLM讀到/
    /// 譯文/來源)。縮圖、重試標記、兩次原始輸出這些只有要深入除錯才需要的東西,
    /// 移進展開內容——沿用 `pageDebugSection` 唯一現成的 `DisclosureGroup` 寫法,
    /// 不引入新元件。四塊全部固定展開時畫面會塞進 2 張縮圖+6 行文字,裝機截圖
    /// 很快就爆版,收合掉才看得清楚。
    private var debugList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(blocks) { block in
                    DisclosureGroup {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(spacing: 2) {
                                if let crop = cropPreviews[block.id] {
                                    Image(uiImage: crop)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 90, height: 44)
                                        .border(.gray)
                                }
                                if let wider = widerCropPreviews[block.id] {
                                    Image(uiImage: wider)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 90, height: 60)
                                        .border(.orange)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                if block.usedWiderContextRetry {
                                    Text("↻ 已走寬裁圖重試(橘框=重試看到的圖)")
                                        .foregroundStyle(.orange)
                                    if let first = block.firstAttemptRawOutput {
                                        Text("第1次原始輸出:\(Self.debugTruncated(first))")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let raw = block.rawOutput {
                                    Text("\(block.usedWiderContextRetry ? "重試" : "")原始輸出:\(Self.debugTruncated(raw))")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.top, 2)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vision:\(block.visionText)")
                            if let recognized = block.recognizedText, !recognized.isEmpty {
                                Text("VLM讀到:\(recognized)")
                            }
                            Text("譯文:\(block.translatedText ?? "…")")
                            Text(Self.sourceLine(for: block))
                                .foregroundStyle(block.source == .wholePage ? .green : .secondary)
                        }
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 整頁模式上方多了 pageDebugSection,清單高度收一點,不要把上面的圖擠掉。
        .frame(height: 260)
    }

    /// 每列的「這段譯文哪來的」說明。整頁對位成功時附上相似度分數,方便用實測
    /// 數字校準 `pageMatchThreshold`,不要再用猜的。
    private static func sourceLine(for block: TextBlock) -> String {
        switch block.source {
        case .none:
            return "來源:—"
        case .wholePage:
            let index = block.matchedItemIndex.map { "#\($0)" } ?? "?"
            let score = block.matchScore.map { String(format: "%.2f", $0) } ?? "?"
            return "來源:整頁 \(index) 分數 \(score)"
        case .regionFallback:
            return "來源:逐塊(整頁沒對到)"
        }
    }

    /// 整頁模式專用的頁層級除錯區段。
    ///
    /// 整頁原始輸出是本輪最重要的除錯產物:一張截圖就能同時回答「模型有沒有讀對難字」
    /// 「有沒有卡迴圈」「總共列了幾塊」「順序對不對」——而且**與對位成功與否無關**,
    /// 所以要完整顯示、可展開、可複製,不能截斷。
    @ViewBuilder
    private var pageDebugSection: some View {
        if engineKind == .visionPage && !pageRawOutput.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("整頁輸出 \(pageItemCount) 項 / Vision 定位 \(blocks.count) 塊")
                if pageItemCount != blocks.count {
                    Text("⚠️ 數量不符,整批退回逐塊(不做猜測性對位)")
                        .foregroundStyle(.orange)
                }
                DisclosureGroup("整頁原始輸出(\(pageRawOutput.count) 字)") {
                    Text(pageRawOutput)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 卡進重複迴圈的原始輸出可能長達上百字元,全部顯示會把清單撐爆,
    /// 但要看得出「是重複迴圈還是別的失敗」,所以留頭尾各一段。
    private static func debugTruncated(_ text: String, head: Int = 60, tail: Int = 20) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        guard flat.count > head + tail + 5 else { return flat }
        return "\(flat.prefix(head))…(共\(flat.count)字)…\(flat.suffix(tail))"
    }

    private func runPipeline() async {
        guard let rawImage = image else {
            status = "找不到測試圖片(Fixtures/sample-es.jpg 沒被打包進去?)"
            return
        }
        // 統一座標系:.up 方向 + 像素尺寸(裁圖需要精確像素,疊字用比例運算原本
        // 用「點」也沒事,但兩邊統一用像素比較不容易踩到 @2x/@3x 的坑)。
        let page = RegionCropper.normalizedUp(rawImage)
        guard let cg = page.cgImage else {
            status = "圖片沒有 cgImage"
            return
        }
        let pixelWidth = cg.width
        let pixelHeight = cg.height
        imageSize = CGSize(width: pixelWidth, height: pixelHeight)
        cropPreviews = [:]
        widerCropPreviews = [:]
        pageRawOutput = ""
        pageItemCount = 0

        status = "OCR 定位中…"
        do {
            let recognized = try await TextRecognizer.recognizeText(
                in: page,
                recognitionLanguages: [visionRecognitionLanguage(for: sourceLanguage), "en-US"]
            )

            // 先合併同一對話框裡被 Vision 拆成多行的 bbox,再裁圖/翻譯——
            // VLM 呼叫次數減半以上,而且能看到完整語句上下文(見 README)。
            let regions = RegionMerger.merge(recognized, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            blocks = regions.map {
                TextBlock(visionText: $0.visionText, recognizedText: nil,
                          translatedText: nil, pixelRect: $0.pixelRect)
            }
            status = "定位到 \(blocks.count) 個文字區塊,翻譯中…"

            switch engineKind {
            case .text:
                try await runTextPipeline()
            case .visionRegion:
                try await runVisionPipeline(page: page, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            case .visionPage:
                try await runVisionPagePipeline(page: page, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            }
            status = "完成"
        } catch {
            status = "失敗:\(error.localizedDescription)"
        }
    }

    /// 文字引擎路線:整批純文字丟給 TranslateGemma 翻,一次拿全部結果。
    private func runTextPipeline() async throws {
        let translated = try await localEngine.translate(
            blocks.map { $0.visionText },
            from: sourceLanguage,
            to: targetLanguage
        )
        for i in blocks.indices where i < translated.count {
            blocks[i].translatedText = translated[i]
        }
    }

    /// 視覺引擎路線:逐塊裁圖丟給 VLM 讀字+翻譯,每完成一塊立刻更新畫面
    /// (每塊約 2-4 秒,一次等全部做完會讓使用者盯著空白畫面很久)。
    private func runVisionPipeline(page: UIImage, pixelWidth: Int, pixelHeight: Int) async throws {
        for i in blocks.indices {
            let cropRect = RegionCropper.padded(
                blocks[i].pixelRect, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            guard let crop = RegionCropper.crop(page, toPixelRect: cropRect) else { continue }
            cropPreviews[blocks[i].id] = UIImage(cgImage: crop)

            // 只在 VLM 判定主要路線生成失敗時才會用到,同一位置但擴邊範圍大很多
            // (整個對話框/分鏡),讓模型有機會靠上下文正確讀出孤立小裁圖讀不出來的字
            // (裝機實測發現同一顆模型透過 Locally AI 看整張圖讀得出來,見
            // `VLMTranslationEngine.translateRegion` 的說明)。
            let widerRect = RegionCropper.padded(
                blocks[i].pixelRect, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                padFractionX: 1.5, padFractionY: 4.0, minPadPixels: 60)
            let widerCrop = RegionCropper.crop(page, toPixelRect: widerRect)

            let result = try await vlmEngine.translateRegion(
                crop, widerContext: widerCrop, from: sourceLanguage, to: targetLanguage)
            blocks[i].recognizedText = result.recognizedText
            blocks[i].translatedText = result.translatedText
            blocks[i].rawOutput = result.rawOutput
            blocks[i].usedWiderContextRetry = result.usedWiderContextRetry
            blocks[i].firstAttemptRawOutput = result.firstAttemptRawOutput
            blocks[i].source = .regionFallback
            // 走過重試才留寬裁圖縮圖,用來確認「寬裁圖到底裁到什麼」(範圍夠不夠、
            // 有沒有反而吃到隔壁分鏡),沒走重試就不佔記憶體。
            if result.usedWiderContextRetry, let widerCrop {
                widerCropPreviews[blocks[i].id] = UIImage(cgImage: widerCrop)
            }
        }
        vlmEngine.finishPage()
    }

    /// 整頁引擎路線:整頁丟給 VLM 一次讀完 → 依閱讀順序把結果配回 Vision 的 bbox
    /// → 沒配到的區塊自動退回逐塊路線。
    ///
    /// 「沒配到就退回」這個設計是刻意的保險:整頁路線整個失敗時,結果等於今天的
    /// 行為,不可能比今天差——這是第六輪「為了救難字動全域 prompt、結果把原本翻對
    /// 的句子搞壞」留下的教訓。
    private func runVisionPagePipeline(page: UIImage, pixelWidth: Int, pixelHeight: Int) async throws {
        guard let pageCG = page.cgImage else { return }

        // 先把每塊的裁圖縮圖無條件備好(純 CGImage.cropping,不含推理,成本可忽略)。
        // 整頁路線不會進逐塊迴圈,不先做的話除錯清單整排沒有縮圖,失去定位問題的能力。
        var crops: [Int: CGImage] = [:]
        for i in blocks.indices {
            let rect = RegionCropper.padded(
                blocks[i].pixelRect, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            if let crop = RegionCropper.crop(page, toPixelRect: rect) {
                crops[i] = crop
                cropPreviews[blocks[i].id] = UIImage(cgImage: crop)
            }
        }

        status = "整頁讀圖翻譯中…"
        if let pageResult = try await vlmEngine.translatePage(
            pageCG, expectedBlockCount: blocks.count,
            from: sourceLanguage, to: targetLanguage) {

            pageRawOutput = pageResult.rawOutput
            pageItemCount = pageResult.items.count

            // 數量必須完全相符才做順序對位。數量不符就整批退回逐塊,不做任何
            // 猜測性對位——Vision 的 bbox 是回填唯一依據,把譯文綁到錯的框會變成
            // 「看起來成功、其實是錯的」沉默失敗,比明確失敗更難發現、更貴。
            if pageResult.items.count == blocks.count {
                for i in blocks.indices {
                    let item = pageResult.items[i]
                    guard !item.isDegenerate, !item.translated.isEmpty else { continue }
                    let score = PageOutputParser.similarity(
                        PageOutputParser.fold(item.original),
                        PageOutputParser.fold(blocks[i].visionText))
                    guard score >= Self.pageMatchThreshold else { continue }

                    blocks[i].recognizedText = item.original
                    blocks[i].translatedText = item.translated
                    blocks[i].rawOutput = item.rawSlice
                    blocks[i].source = .wholePage
                    blocks[i].matchedItemIndex = item.index
                    blocks[i].matchScore = score
                }
            }
        }

        // 整頁沒填到的區塊退回逐塊路線(這段與 runVisionPipeline 完全相同)。
        for i in blocks.indices where blocks[i].translatedText == nil {
            guard let crop = crops[i] else { continue }
            status = "整頁沒對到的區塊改用逐塊翻譯…"
            let widerRect = RegionCropper.padded(
                blocks[i].pixelRect, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                padFractionX: 1.5, padFractionY: 4.0, minPadPixels: 60)
            let widerCrop = RegionCropper.crop(page, toPixelRect: widerRect)

            let result = try await vlmEngine.translateRegion(
                crop, widerContext: widerCrop, from: sourceLanguage, to: targetLanguage)
            blocks[i].recognizedText = result.recognizedText
            blocks[i].translatedText = result.translatedText
            blocks[i].rawOutput = result.rawOutput
            blocks[i].usedWiderContextRetry = result.usedWiderContextRetry
            blocks[i].firstAttemptRawOutput = result.firstAttemptRawOutput
            blocks[i].source = .regionFallback
            if result.usedWiderContextRetry, let widerCrop {
                widerCropPreviews[blocks[i].id] = UIImage(cgImage: widerCrop)
            }
        }
        vlmEngine.finishPage()
    }
}

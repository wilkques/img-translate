import SwiftUI
import UIKit
import Foundation

struct ContentView: View {
    enum EngineKind: String, CaseIterable {
        case vision = "視覺模型(VLM 讀圖)"
        case text = "文字模型(OCR+TranslateGemma)"
    }

    @State private var blocks: [TextBlock] = []
    @State private var cropPreviews: [UUID: UIImage] = [:]
    /// 只有走過寬範圍裁圖重試的區塊才有,用來確認重試實際看到的圖長什麼樣。
    @State private var widerCropPreviews: [UUID: UIImage] = [:]
    @State private var showTranslated = true
    @State private var status = "準備中…"
    @State private var imageSize: CGSize = .zero
    @State private var smokeTestResult = ""
    @State private var engineKind: EngineKind = .vision
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
                case .vision: localEngine.unload()
                case .text: vlmEngine.unload()
                }
            }

            switch engineKind {
            case .text: localEngineStatusLine
            case .vision: vlmEngineStatusLine
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
    private var debugList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(blocks) { block in
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
                            Text("Vision:\(block.visionText)")
                            if let recognized = block.recognizedText, !recognized.isEmpty {
                                Text("VLM讀到:\(recognized)")
                            }
                            Text("譯文:\(block.translatedText ?? "…")")

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
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 300)
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
            case .vision:
                try await runVisionPipeline(page: page, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
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
            // 走過重試才留寬裁圖縮圖,用來確認「寬裁圖到底裁到什麼」(範圍夠不夠、
            // 有沒有反而吃到隔壁分鏡),沒走重試就不佔記憶體。
            if result.usedWiderContextRetry, let widerCrop {
                widerCropPreviews[blocks[i].id] = UIImage(cgImage: widerCrop)
            }
        }
        vlmEngine.finishPage()
    }
}

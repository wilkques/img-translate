import SwiftUI
import UIKit
import Foundation

struct ContentView: View {
    @State private var blocks: [TextBlock] = []
    @State private var showTranslated = true
    @State private var status = "準備中…"
    @State private var imageSize: CGSize = .zero
    @State private var smokeTestResult = ""
    @StateObject private var appleEngine = AppleTranslationEngine()
    @StateObject private var localEngine = LocalLLMTranslationEngine()

    enum EngineChoice: String, CaseIterable {
        case apple = "系統翻譯(已知會卡住)"
        case local = "本機模型(MLX)"
    }

    // Apple Translation 已確認在 LiveContainer 下會永遠卡住(debugLog 定位到
    // session.translations(from:) 本身卡死),預設改選本機模型。
    @State private var engineChoice: EngineChoice = .local

    private let image: UIImage? = {
        guard let path = Bundle.main.path(forResource: "sample-es", ofType: "jpg"),
              let img = UIImage(contentsOfFile: path) else { return nil }
        return img
    }()

    @State private var sourceLanguage = "es"
    @State private var targetLanguage = "zh-Hant-TW"

    /// 這次先用固定清單(涵蓋 Apple Translation 常見支援語言),不即時查
    /// `LanguageAvailability` API——那個 API 回傳的是裝置「大致支援」的語言,
    /// 不代表某個特定語言對一定能翻,實際能不能翻由 runPipeline() 執行時
    /// 的錯誤訊息反映出來(session.translations 丟出的 error 會顯示在狀態列)。
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
                                    forNormalizedVisionBox: block.normalizedBoundingBox,
                                    imagePixelSize: imageSize,
                                    containerSize: geo.size
                                )
                                BubbleOverlayView(text: block.translatedText ?? block.originalText, rect: rect)
                            }
                        }
                    }
                    .background(TranslationBridge(engine: appleEngine))
                }

                Text(status).font(.caption).foregroundStyle(.secondary)

                debugList

                Button(showTranslated ? "顯示原圖" : "顯示疊字翻譯") {
                    showTranslated.toggle()
                }
                .buttonStyle(.borderedProminent)

                mlxSmokeTestSection

                appleTranslationDebugSection
            }
            .padding()
            .navigationTitle("ImgTranslate")
            .task(id: "\(sourceLanguage)|\(targetLanguage)|\(engineChoice.rawValue)") { await runPipeline() }
        }
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("翻譯引擎", selection: $engineChoice) {
                ForEach(EngineChoice.allCases, id: \.self) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            if engineChoice == .local {
                localEngineStatusLine
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
    /// 不下載任何模型——先確認環境,通過才值得投入 Stage 2(真正接模型)。
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

    /// 診斷用:定位 Apple Translation 卡住的位置是 SwiftUI 層(.translationTask 沒觸發)
    /// 還是系統 API 本身(session.translations(from:) 卡住)。
    private var appleTranslationDebugSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Apple Translation 診斷 log").font(.caption).bold()
            ForEach(Array(appleEngine.debugLog.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 顯示 Vision 實際辨識出的原文,方便判斷「辨識錯」還是「翻譯錯」
    private var debugList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(blocks) { block in
                    Text("原文:\(block.originalText)　→　譯文:\(block.translatedText ?? "…")")
                        .font(.system(.caption2, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 160)
    }

    private func runPipeline() async {
        guard let image else {
            status = "找不到測試圖片(Fixtures/sample-es.jpg 沒被打包進去?)"
            return
        }
        imageSize = image.size
        status = "OCR 辨識中…"
        do {
            let recognized = try await TextRecognizer.recognizeText(
                in: image,
                recognitionLanguages: [visionRecognitionLanguage(for: sourceLanguage), "en-US"]
            )
            blocks = recognized.map {
                TextBlock(originalText: $0.text, translatedText: nil, normalizedBoundingBox: $0.normalizedBoundingBox)
            }
            status = "辨識到 \(blocks.count) 段文字,翻譯中…"

            let translated: [String]
            switch engineChoice {
            case .apple:
                translated = try await appleEngine.translate(
                    blocks.map { $0.originalText },
                    from: sourceLanguage,
                    to: targetLanguage
                )
            case .local:
                translated = try await localEngine.translate(
                    blocks.map { $0.originalText },
                    from: sourceLanguage,
                    to: targetLanguage
                )
            }
            for i in blocks.indices where i < translated.count {
                blocks[i].translatedText = translated[i]
            }
            status = "完成"
        } catch {
            status = "失敗:\(error.localizedDescription)"
        }
    }
}

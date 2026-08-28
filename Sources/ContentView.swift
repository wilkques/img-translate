import SwiftUI
import UIKit
import Foundation

struct ContentView: View {
    @State private var blocks: [TextBlock] = []
    @State private var showTranslated = true
    @State private var status = "準備中…"
    @State private var imageSize: CGSize = .zero
    @State private var smokeTestResult = ""
    @StateObject private var localEngine = LocalLLMTranslationEngine()

    private let image: UIImage? = {
        guard let path = Bundle.main.path(forResource: "sample-es", ofType: "jpg"),
              let img = UIImage(contentsOfFile: path) else { return nil }
        return img
    }()

    @State private var sourceLanguage = "es"
    @State private var targetLanguage = "zh-Hant-TW"

    /// 固定清單,對應 `LocalLLMTranslationEngine.languageNameMap` 有映射的語言代碼。
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

                localEngineStatusLine

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
            .task(id: "\(sourceLanguage)|\(targetLanguage)") { await runPipeline() }
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

            let translated = try await localEngine.translate(
                blocks.map { $0.originalText },
                from: sourceLanguage,
                to: targetLanguage
            )
            for i in blocks.indices where i < translated.count {
                blocks[i].translatedText = translated[i]
            }
            status = "完成"
        } catch {
            status = "失敗:\(error.localizedDescription)"
        }
    }
}

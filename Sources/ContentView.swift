import SwiftUI

struct ContentView: View {
    @State private var blocks: [TextBlock] = []
    @State private var showTranslated = true
    @State private var status = "準備中…"
    @State private var imageSize: CGSize = .zero
    @StateObject private var appleEngine = AppleTranslationEngine()

    private let image: UIImage? = {
        guard let path = Bundle.main.path(forResource: "sample-es", ofType: "jpg"),
              let img = UIImage(contentsOfFile: path) else { return nil }
        return img
    }()

    private let sourceLanguage = "es"
    private let targetLanguage = "zh-Hant-TW"

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
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
            }
            .padding()
            .navigationTitle("ImgTranslate")
            .task { await runPipeline() }
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
                recognitionLanguages: ["\(sourceLanguage)-ES", "en-US"]
            )
            blocks = recognized.map {
                TextBlock(originalText: $0.text, translatedText: nil, normalizedBoundingBox: $0.normalizedBoundingBox)
            }
            status = "辨識到 \(blocks.count) 段文字,翻譯中…"

            let translated = try await appleEngine.translate(
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

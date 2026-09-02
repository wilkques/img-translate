import SwiftUI

/// 網頁漫畫閱讀畫面:輸入網址、捲動頁面,圖片進視窗前就先跑 OCR+VLM 翻譯,
/// 完成後直接疊字回填到網頁的 DOM 上(不是原生疊字)。
///
/// 翻譯 pipeline 完全沿用 `Sources/OCR/*`、`Sources/Translation/*`——跟
/// 「引擎測試」分頁(`ContentView`)背後是同一套邏輯,只是圖片來源從固定
/// 測試圖換成網頁上抓下來的圖。
///
/// ⚠️ 已知限制:這個畫面自己養一份 `VLMTranslationEngine`,跟「引擎測試」
/// 分頁那份是**兩個獨立實例**。平常只會用其中一個分頁不會有問題,但如果
/// 兩邊都在同一個 session 裡觸發翻譯,可能同時嘗試載入模型(各自 3GB+)。
/// 這輪先不處理(需要把引擎持有者上移到 App 層級才能共用,牽動
/// `ContentView` 的既有結構),留給下一輪再評估要不要做。
struct MangaReaderView: View {
    @StateObject private var vlmEngine: VLMTranslationEngine
    @StateObject private var coordinator: TranslationRequestCoordinator
    @State private var urlField = ""
    @State private var loadedURL: URL?

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

    init() {
        let engine = VLMTranslationEngine()
        _vlmEngine = StateObject(wrappedValue: engine)
        _coordinator = StateObject(wrappedValue: TranslationRequestCoordinator(vlmEngine: engine))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("貼上漫畫網址", text: $urlField)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .onSubmit(loadURL)
                Button("前往", action: loadURL)
                    .buttonStyle(.borderedProminent)
            }

            languagePickers

            Text(coordinator.pageStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            vlmEngineStatusLine

            MangaWebView(urlToLoad: loadedURL, coordinator: coordinator)
                .frame(maxHeight: .infinity)

            Text("偵測到的圖片(\(coordinator.probes.count))")
                .font(.caption).bold()
                .frame(maxWidth: .infinity, alignment: .leading)

            probeDebugList
        }
        .padding()
    }

    private var languagePickers: some View {
        HStack {
            Picker("來源語言", selection: $coordinator.sourceLanguage) {
                ForEach(languageOptions, id: \.code) { option in
                    Text(option.label).tag(option.code)
                }
            }
            Text("→")
            Picker("目標語言", selection: $coordinator.targetLanguage) {
                ForEach(languageOptions, id: \.code) { option in
                    Text(option.label).tag(option.code)
                }
            }
        }
        .pickerStyle(.menu)
        .font(.caption)
    }

    @ViewBuilder
    private var vlmEngineStatusLine: some View {
        switch vlmEngine.phase {
        case .idle:
            EmptyView()
        case .downloading(let fraction):
            let gb = Double(vlmEngine.selectedModel.approximateDownloadBytes) / 1_000_000_000
            ProgressView(value: fraction) {
                Text("下載視覺模型中 \(Int(fraction * 100))%(約 \(String(format: "%.1f", gb))GB,首次執行請連 WiFi)")
                    .font(.caption2)
            }
        case .loadingWeights:
            ProgressView { Text("載入模型權重中…").font(.caption2) }
        case .warmingUp:
            ProgressView { Text("首次暖機中(編譯 Metal pipeline)…").font(.caption2) }
        case .translating(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("翻譯中 \(done)/\(total)").font(.caption2)
            }
        case .ready:
            Text("視覺模型就緒").font(.caption2).foregroundStyle(.secondary)
        case .failed(let message):
            Text("視覺模型失敗:\(message)").font(.caption2).foregroundStyle(.red)
        }
    }

    private func loadURL() {
        guard let url = normalizedURL(from: urlField) else { return }
        loadedURL = url
    }

    private func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://\(trimmed)")
    }

    private var probeDebugList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(coordinator.probes) { probe in
                    Text(Self.line(for: probe))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Self.color(for: probe.status))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 200)
    }

    private static func line(for probe: TranslationRequestCoordinator.ImageProbe) -> String {
        let shortURL = probe.url.lastPathComponent.isEmpty
            ? probe.url.absoluteString
            : probe.url.lastPathComponent
        switch probe.status {
        case .detected:
            return "🔍 偵測到:\(shortURL)"
        case .downloading:
            return "⬇️ 下載中:\(shortURL)"
        case .translating:
            return "🌀 翻譯中:\(shortURL)"
        case .translated(let count):
            return "✅ \(shortURL) — 已疊字 \(count) 個區塊"
        case .noTextFound:
            return "▫️ \(shortURL) — 沒偵測到文字"
        case .failed(let message):
            return "❌ \(shortURL) — \(message)"
        }
    }

    private static func color(for status: TranslationRequestCoordinator.ImageProbe.Status) -> Color {
        switch status {
        case .detected, .downloading, .translating: return .secondary
        case .translated: return .green
        case .noTextFound: return .secondary
        case .failed: return .red
        }
    }
}

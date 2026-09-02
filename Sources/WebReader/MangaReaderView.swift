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
///
/// ⚠️ 2026-09-02:裝機實測 Jetsam 記錄證實連續處理多張網頁圖會把 App 記憶體
/// 推到 LiveContainer 側載環境約 6GB 的上限(`reason: per-process-limit`)。
/// 試過換小模型(`Qwen3-VL-2B`/`Qwen2.5-VL-3B`)解決 OOM,也試過保留 `4B`
/// 但每張圖處理完整個卸載模型——後者裝機直接 SIGABRT(卸載動作跟 Metal
/// 非同步完成回呼搶時序,是比 OOM 更難排查的當機),已收回。最終定案:
/// 固定用 `Qwen2.5-VL-3B`,搭配放寬過的 retry prompt(見
/// `VLMTranslationEngine.makeRetryPrompt`),翻譯品質堪用且沒有額外當機
/// 風險。模型選單保留,想手動試別的模型可以自己切,但預設不追求 `4B`。
struct MangaReaderView: View {
    @StateObject private var vlmEngine: VLMTranslationEngine
    @StateObject private var coordinator: TranslationRequestCoordinator
    @State private var urlField = ""
    @State private var loadedURL: URL?
    @FocusState private var isURLFieldFocused: Bool

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
        // 2026-09-02:曾經試過「每張圖處理完整個卸載模型」換回 4B 的品質,
        // 裝機直接 SIGABRT——卸載動作跟 Metal 命令佇列的非同步完成回呼搶時序,
        // 引入了新的當機(比原本的 OOM 更難排查),已經整個收回。改用固定
        // 選 `Qwen2.5-VL-3B`:retry prompt 放寬後翻譯品質已經算堪用,且不會
        // 動到模型容器生命週期這塊、沒有額外的當機風險。
        let engine = VLMTranslationEngine()
        engine.selectedModel = .qwen2_5VL3B
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
                    .focused($isURLFieldFocused)
                    .onSubmit(loadURL)
                Button("前往", action: loadURL)
                    .buttonStyle(.borderedProminent)
            }

            languagePickers

            modelPicker

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

    /// 模型選單+下載/移除按鈕,寫法照抄 `ContentView.enginePicker` 那段。
    /// 記憶體吃緊(見上面 2026-09-02 說明)時,直接在這裡換小一點的模型
    /// 不用重新編譯裝機。
    private var modelPicker: some View {
        HStack {
            let isDownloaded = vlmEngine.downloadedModels.contains(vlmEngine.selectedModel)
            Button(isDownloaded ? "移除模型" : "下載模型") {
                if isDownloaded {
                    vlmEngine.removeDownload(of: vlmEngine.selectedModel)
                } else {
                    Task { try? await vlmEngine.ensureLoaded() }
                }
            }
            .font(.caption)
            .foregroundStyle(isDownloaded ? .red : .accentColor)

            // 用自訂 Binding 呼叫 `changeModel(to:)`,不能直接綁 `$vlmEngine.selectedModel`
            // ——直接綁會跳過「換模型前要先卸載舊模型」的保護,`ensureLoaded()`
            // 可能誤用還沒卸載的舊 container,這正是這輪在追的記憶體問題,不能
            // 再引入新的雙模型風險。寫法照抄 `ContentView.enginePicker`。
            Picker("VLM 模型", selection: Binding(
                get: { vlmEngine.selectedModel },
                set: { vlmEngine.changeModel(to: $0) }
            )) {
                ForEach(VLMTranslationEngine.VLMModelOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)
        }
        .onAppear { vlmEngine.refreshDownloadedModels() }
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
        isURLFieldFocused = false
        guard let url = normalizedURL(from: urlField) else { return }
        loadedURL = url
    }

    private func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://\(trimmed)")
    }

    /// 每列預設收合,只留摘要行;展開才看得到逐區塊「Vision 辨識/VLM 讀到/
    /// 譯文/來源」明細,樣式照抄 `ContentView` 的除錯清單。這份明細是為了
    /// 追「兩個不同原文疊出同一句譯文」這類問題新增的(2026-09-02)——只有
    /// 成功/失敗筆數沒辦法定位是配對邏輯錯還是模型讀錯。
    private var probeDebugList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(coordinator.probes) { probe in
                    if probe.blocks.isEmpty {
                        Text(Self.line(for: probe))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Self.color(for: probe.status))
                            .textSelection(.enabled)
                    } else {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(probe.blocks) { block in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("Vision:\(block.visionText)")
                                        Text("VLM讀到:\(block.recognizedText)")
                                        Text("譯文:\(block.translatedText)")
                                        Text("來源:\(block.source)").foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.top, 2)
                        } label: {
                            Text(Self.line(for: probe))
                                .foregroundStyle(Self.color(for: probe.status))
                        }
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 240)
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

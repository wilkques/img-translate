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
    /// 除錯清單的高度,靠 `debugListResizeHandle` 拖曳調整——Cyril 要求圖片
    /// 顯示區可以拉伸、底下的文字清單可以上下拉,兩者是同一件事的兩面:清單
    /// 拉高,`MangaWebView`(`.frame(maxHeight: .infinity)`)自動讓出空間;
    /// 清單拉低,圖片顯示區跟著變高。
    @State private var debugListHeight: CGFloat = 200
    @State private var debugListDragStartHeight: CGFloat?

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

            // 2026-09-03:實驗開關,測試「OCR 文字直接丟 VLM 翻譯」能不能取代
            // 較慢的讀圖路線,見 `TranslationRequestCoordinator.useTextOnlyTranslation`
            // 的說明。放在這裡方便跟語言/模型選單一起看,不用捲到除錯清單才找得到。
            Toggle("純文字模式(實驗:跳過讀圖,OCR 文字直接翻)", isOn: $coordinator.useTextOnlyTranslation)
                .font(.caption2)

            HStack {
                Text(coordinator.pageStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                // 2026-09-03:Cyril 要求「開始翻譯」要明確觸發,不要一偵測到
                // 圖片就自動下載+排隊翻譯——見 `TranslationRequestCoordinator.
                // isAutoTranslateEnabled` 的說明。這顆按鈕只負責「邊捲邊翻」
                // 那條路線,跟下面「翻譯整話」是兩個獨立的開始方式。
                Button(coordinator.isAutoTranslateEnabled ? "翻譯中" : "開始翻譯") {
                    coordinator.startAutoTranslate()
                }
                .font(.caption2)
                .disabled(coordinator.isAutoTranslateEnabled || loadedURL == nil)

                // 2026-09-03:Cyril 確認「追求品質」——邊捲邊翻永遠追不上
                // VLM 速度,改成這顆按鈕觸發「整話全部翻完才給看」,見
                // `TranslationRequestCoordinator.startPreTranslateAll` 的說明。
                Button(coordinator.isPreTranslating ? "翻譯整話中…" : "翻譯整話") {
                    coordinator.startPreTranslateAll()
                }
                .font(.caption2)
                .disabled(coordinator.isPreTranslating || loadedURL == nil)

                // 2026-09-03:Cyril 要求可以暫停/繼續——只擋佇列啟動下一個
                // 工作,不中斷正在跑的那一個,見 `TranslationRequestCoordinator.
                // pauseTranslation`/`resumeTranslation` 的說明。兩種開始翻譯
                // 的方式(開始翻譯/翻譯整話)都會打開 `isAutoTranslateEnabled`,
                // 用同一個開關判斷這顆按鈕該不該顯示可按。
                Button(coordinator.isPaused ? "繼續" : "暫停") {
                    if coordinator.isPaused {
                        coordinator.resumeTranslation()
                    } else {
                        coordinator.pauseTranslation()
                    }
                }
                .font(.caption2)
                .disabled(!coordinator.isAutoTranslateEnabled)
            }

            ZStack {
                MangaWebView(urlToLoad: loadedURL, coordinator: coordinator)
                    .frame(maxHeight: .infinity)
                if coordinator.isPreTranslating {
                    preTranslateOverlay
                }
            }
            .frame(maxHeight: .infinity)

            debugListResizeHandle

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
        .font(.caption2)
    }

    /// 模型選單+下載/移除按鈕+模型狀態,全部擠在同一行、字級縮小——Cyril
    /// 要求「翻譯中」狀態跟選擇模型排版在同一行、整體縮小,把空間讓給下面
    /// 的網頁圖片顯示區。原本 `vlmEngineStatusLine` 是獨立一段、帶完整的
    /// `ProgressView` 進度條,現在濃縮成一小段文字接在選單後面——只求「看得
    /// 出目前卡在哪個階段」,不追求完整的進度條視覺效果。
    private var modelPicker: some View {
        HStack(spacing: 6) {
            let isDownloaded = vlmEngine.downloadedModels.contains(vlmEngine.selectedModel)
            Button(isDownloaded ? "移除" : "下載") {
                if isDownloaded {
                    vlmEngine.removeDownload(of: vlmEngine.selectedModel)
                } else {
                    Task { try? await vlmEngine.ensureLoaded() }
                }
            }
            .font(.caption2)
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
            .font(.caption2)

            Spacer(minLength: 4)

            compactVLMStatusText
        }
        .onAppear { vlmEngine.refreshDownloadedModels() }
    }

    /// `vlmEngineStatusLine` 濃縮版,塞進 `modelPicker` 那一行右側。
    @ViewBuilder
    private var compactVLMStatusText: some View {
        switch vlmEngine.phase {
        case .idle:
            EmptyView()
        case .downloading(let fraction):
            Text("下載 \(Int(fraction * 100))%")
        case .loadingWeights:
            Text("載入中…")
        case .warmingUp:
            Text("暖機中…")
        case .translating(let done, let total):
            Text("翻譯 \(done)/\(total)")
        case .ready:
            Text("就緒").foregroundStyle(.secondary)
        case .failed:
            Text("模型失敗").foregroundStyle(.red)
        }
    }

    /// 拖曳把手——上下拖動調整 `debugListHeight`,直接決定除錯清單佔多高、
    /// 反過來就是網頁圖片顯示區(`.frame(maxHeight: .infinity)`)還剩多少
    /// 空間。用 `debugListDragStartHeight` 記住拖曳「開始那一刻」的高度,
    /// 每次 `onChanged` 都以這個固定基準加上本次拖曳的**累計位移**去算,
    /// 不能直接拿目前的 `debugListHeight` 去疊加——`DragGesture.translation`
    /// 本身就是「從拖曳開始算起的累計值」,兩個累計值疊加會越拖越誇張。
    private var debugListResizeHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let base = debugListDragStartHeight ?? debugListHeight
                        if debugListDragStartHeight == nil { debugListDragStartHeight = debugListHeight }
                        // 手指往上拖(translation.height 是負的)代表要把清單
                        // 拉高、往下拖代表要把清單壓低,所以是「基準 - 位移」。
                        debugListHeight = min(max(base - value.translation.height, 80), 500)
                    }
                    .onEnded { _ in debugListDragStartHeight = nil }
            )
    }

    /// 「整話先翻完再看」的進度遮罩——蓋住 `MangaWebView`,擋住閱讀直到全部
    /// 翻完。`total` 用 `preTranslateTotal ?? probes.count` 是因為 JS 那次
    /// `evaluateJavaScript` 呼叫還沒回應前 `preTranslateTotal` 是 `nil`,這時
    /// 先顯示「掃描圖片中」而不是顯示 0/0(看起來像已經完成)。
    private var preTranslateOverlay: some View {
        let done = coordinator.probes.filter { Self.isSettled($0.status) }.count
        let total = coordinator.preTranslateTotal
        return VStack(spacing: 12) {
            ProgressView()
            if let total {
                Text(total > 0 ? "翻譯整話中 \(done)/\(total)" : "這頁沒找到符合條件的圖片")
                    .font(.callout)
            } else {
                Text("掃描圖片中…")
                    .font(.callout)
            }
            Button("先看已翻好的部分") {
                coordinator.skipPreTranslateWait()
            }
            .font(.caption)
        }
        .padding()
        .background(.regularMaterial)
        .cornerRadius(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.25))
    }

    private static func isSettled(_ status: TranslationRequestCoordinator.ImageProbe.Status) -> Bool {
        switch status {
        case .detected, .downloading, .translating: return false
        case .translated, .noTextFound, .failed: return true
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
                    HStack(alignment: .top, spacing: 6) {
                        Group {
                            if probe.blocks.isEmpty {
                                Text(Self.line(for: probe))
                                    .foregroundStyle(Self.color(for: probe.status))
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
                            }
                        }
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)

                        // Cyril 要求:能直接點選重來,不用重新整頁重新捲一次,
                        // 而且不要只在失敗時才給——見 `isRetryable` 的說明,
                        // 只排除正在下載/翻譯中的狀態。
                        if Self.isRetryable(probe.status) {
                            Button {
                                coordinator.retryTranslation(for: probe.url)
                            } label: {
                                Image(systemName: "arrow.clockwise.circle")
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: debugListHeight)
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

    /// ⚠️ 2026-09-03:原本只有 `.failed` 才顯示重試按鈕,Cyril 要求不要隱藏——
    /// 例如 `.noTextFound` 也可能是 OCR 偶發沒抓到、換個時機重跑會抓到,`.translated`
    /// 也可能想換了目標語言後重新翻一次。改成**只排除正在進行中的兩個狀態**
    /// (`.downloading`/`.translating`)——這兩個狀態下面 `TranslationRequestCoordinator`
    /// 已經有一個非同步流程在跑,這時候點重試會對同一個網址再排一次
    /// `downloadAndEnqueue`,兩份工作同時處理同一張圖,誰先寫回 `probes` 誰
    /// 就贏,浪費一次推理還可能讓畫面狀態忽快忽慢地跳——這是唯一需要擋的
    /// 情況,其餘狀態都放行。
    private static func isRetryable(_ status: TranslationRequestCoordinator.ImageProbe.Status) -> Bool {
        switch status {
        case .downloading, .translating: return false
        case .detected, .noTextFound, .translated, .failed: return true
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

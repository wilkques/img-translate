import SwiftUI

/// 釘選一筆人名詞庫條目。原文永遠唯讀——手打會破壞
/// `GlossaryStore.normalize` 要求的精確比對,而這正是從除錯清單的
/// 「VLM讀到」欄位開始釘選(而不是另開一個要手動打原文的畫面)的理由。
/// 譯文用模型當下的輸出當初始值,常見情況只是一兩個字翻錯,兩下就改完。
struct GlossaryPinSheet: View {
    let original: String
    @State var translated: String
    @ObservedObject var glossary: GlossaryStore
    @Environment(\.dismiss) private var dismiss

    private var trimmedTranslated: String {
        translated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("原文(不可編輯)") {
                    Text(original)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                Section("譯文") {
                    TextField("輸入正確譯名", text: $translated)
                }
            }
            .navigationTitle("釘選譯名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        glossary.upsert(original: original, translated: trimmedTranslated)
                        dismiss()
                    }
                    .disabled(trimmedTranslated.isEmpty)
                }
            }
        }
    }
}

/// 詞庫清單/刪除入口。錯誤訊息(檔案讀寫失敗)只在這裡出現——絕不阻擋或
/// 打斷翻譯流程本身,見 `GlossaryStore.lastError` 的說明。
///
/// ⚠️ 2026-09-04:多接了 `sourceLanguageCode`/`vlmEngine`/`fetchPageTitle`
/// 三個參數,只為了「自動查找」這顆按鈕——按下去先用 `fetchPageTitle()`
/// 讀目前頁面標題當搜尋起手值,再用自己的 `.sheet(isPresented:)` 疊一層
/// `GlossarySearchSheet`(sheet 疊 sheet,不是透過 `MangaReaderView` 那個
/// 頂層 `ActiveSheet` 做狀態切換——同一個 item-driven sheet 在展示中途換
/// case 容易有轉場的邊角問題,疊一層自己管理比較單純)。
struct GlossaryListSheet: View {
    @ObservedObject var glossary: GlossaryStore
    let sourceLanguageCode: String
    let mangaOrigin: String
    let vlmEngine: VLMTranslationEngine
    let fetchPageTitle: () async -> String
    @Environment(\.dismiss) private var dismiss
    @State private var showSearchSheet = false
    @State private var prefilledSeriesTitle = ""

    var body: some View {
        NavigationStack {
            List {
                if let error = glossary.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if glossary.entries.isEmpty {
                    Text("還沒有釘選任何譯名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(glossary.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.original)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.translated)
                    }
                }
                .onDelete { offsets in
                    glossary.remove(atOffsets: offsets)
                }
            }
            .navigationTitle("人名詞庫")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("自動查找") {
                        Task {
                            prefilledSeriesTitle = await fetchPageTitle()
                            showSearchSheet = true
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showSearchSheet) {
            GlossarySearchSheet(
                seriesTitle: prefilledSeriesTitle, sourceLanguageCode: sourceLanguageCode,
                mangaOrigin: mangaOrigin, glossary: glossary, vlmEngine: vlmEngine)
        }
    }
}

/// 詞庫「自動查找」畫面——抓漫畫名稱查維基百科,找到中文條目就丟給模型
/// 抽取候選名單,使用者勾選確認才會真的存進詞庫(見 `GlossaryStore`)。
///
/// ⚠️ 2026-09-04:這是全新功能,命中率沒有保證——維基百科/中文維基收錄
/// 的多半是有一定知名度、通常也有官方授權的作品,冷門或純靠盜版站流通
/// 的作品很可能查不到。**查不到是預期中的正常結果**,畫面上要如實顯示
/// 「找不到」,不能假裝成功或無聲卡住。抽出來的候選清單品質也沒有保證
/// (wiki 條目品質不一、AI 抽取本身可能有錯)——這正是「一律要勾選確認
/// 才寫進詞庫,絕不自動 upsert」這個設計存在的理由。
struct GlossarySearchSheet: View {
    @State var seriesTitle: String
    let sourceLanguageCode: String
    let mangaOrigin: String
    @ObservedObject var glossary: GlossaryStore
    let vlmEngine: VLMTranslationEngine
    @Environment(\.dismiss) private var dismiss

    private struct Candidate: Identifiable {
        let id = UUID()
        let original: String
        let translated: String
        var isSelected = true
    }

    @State private var statusText = ""
    @State private var errorText: String?
    @State private var candidates: [Candidate] = []
    @State private var isSearching = false
    /// 找到條目時記下來源網址,提供一個「自己去核對」的連結——自動抽取
    /// 的結果不該是黑盒子,使用者可以直接點過去看原始 wiki 條目。
    @State private var foundArticleURL: URL?
    /// `true` 代表這批候選來自 Fandom 備援(`transliterateNameList` 生成),
    /// `false` 代表來自維基百科中文條目(`extractGlossaryCandidates` 查表)。
    /// 兩種可信度天差地遠,見下面 §Fandom 備援的說明,畫面上必須清楚區分。
    @State private var candidatesAreGenerated = false

    private var selectedCount: Int {
        candidates.filter { $0.isSelected }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("作品名稱") {
                    // 刻意可編輯,不能自動送出去搜尋——抓到的頁面標題常常
                    // 混了站名/集數這類樣板文字(例如「Capítulo 104 de XXX
                    // | Olympus Scanlation」),不同站的包裝格式差很多,沒
                    // 辦法寫一套通用規則自動清乾淨,交給使用者自己修剪。
                    TextField("漫畫名稱", text: $seriesTitle)
                    Button(isSearching ? "搜尋中…" : "搜尋") {
                        search()
                    }
                    .disabled(
                        isSearching
                            || seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !statusText.isEmpty {
                    Section {
                        Text(statusText).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).font(.caption).foregroundStyle(.red)
                    }
                }

                if let foundArticleURL {
                    Section {
                        Link("查看中文維基條目來源", destination: foundArticleURL)
                            .font(.caption)
                    }
                }

                if !candidates.isEmpty {
                    if candidatesAreGenerated {
                        Section {
                            Text("⚠️ 以下是 AI 根據 Fandom 角色名單生成的音譯猜測,不是查表結果,請仔細確認再採用")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Section("候選名單(勾選要加入詞庫的)") {
                        ForEach($candidates) { $candidate in
                            Toggle(isOn: $candidate.isSelected) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.original)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(candidate.translated)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("自動查找")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
                if !candidates.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("加入詞庫(已選\(selectedCount))") {
                            for candidate in candidates where candidate.isSelected {
                                glossary.upsert(
                                    original: candidate.original, translated: candidate.translated)
                            }
                            dismiss()
                        }
                        .disabled(selectedCount == 0)
                    }
                }
            }
        }
    }

    private func search() {
        errorText = nil
        candidates = []
        statusText = ""
        foundArticleURL = nil
        candidatesAreGenerated = false
        isSearching = true
        Task { @MainActor in
            do {
                // `GlossaryWikiSearch.search` 是不帶 actor 隔離的自由函式,
                // `onProgress` 被呼叫時實際跑在哪個執行緒不是這裡能保證的
                // ——這個專案已經有太多次因為想當然爾的執行緒假設踩到裝機
                // 才會現形的並行問題(Metal 競態、SIGABRT 等),這裡明講
                // 跳回 MainActor 才碰 `@State`,不依賴隱含的 actor 繼承。
                let result = try await GlossaryWikiSearch.search(
                    seriesTitle: seriesTitle, sourceLanguageCode: sourceLanguageCode
                ) { progress in
                    Task { @MainActor in statusText = progress }
                }
                foundArticleURL = result.zhArticleURL
                statusText = "AI 分析角色名單…"
                let pairs = try await vlmEngine.extractGlossaryCandidates(from: result.zhArticleText)
                isSearching = false
                statusText = ""
                if pairs.isEmpty {
                    errorText = "找到條目「\(result.sourceTitle)」,但沒有抽出可用的人名候選"
                } else {
                    candidates = pairs.map { Candidate(original: $0.original, translated: $0.translated) }
                }
            } catch let wikiError as GlossaryWikiSearchError {
                // ⚠️ 2026-09-04:維基百科查不到時,加一層 Fandom 備援
                // ——起因是「Designated Bully」(= 西班牙文版「El matón a
                // cargo」)維基百科完全查不到(三種標題都查證過),但確實
                // 有專屬 Fandom wiki、有結構清楚的角色分類。見
                // `GlossaryFandomSearch` 的完整說明:這條路是**猜網域
                // slug**,不是搜尋引擎,猜錯就是猜不到,不是另一層保證。
                let wikiStage: String
                if case .notFound(let stage) = wikiError { wikiStage = stage } else { wikiStage = "查詢失敗" }

                statusText = "維基百科查不到,嘗試猜測 Fandom wiki…"
                do {
                    let fandomResult = try await GlossaryFandomSearch.search(seriesTitle: seriesTitle)
                    foundArticleURL = fandomResult.wikiURL
                    statusText = "AI 音譯角色名單(來自 Fandom,非查表結果)…"
                    let pairs = try await vlmEngine.transliterateNameList(
                        fandomResult.characterNames, mangaOrigin: mangaOrigin)
                    isSearching = false
                    statusText = ""
                    if pairs.isEmpty {
                        errorText = "找到 Fandom wiki「\(fandomResult.wikiTitle)」,但沒有生成出可用的候選"
                    } else {
                        candidatesAreGenerated = true
                        candidates = pairs.map { Candidate(original: $0.original, translated: $0.translated) }
                    }
                } catch let fandomError as GlossaryWikiSearchError {
                    isSearching = false
                    statusText = ""
                    if case .notFound(let fandomStage) = fandomError {
                        errorText = "\(wikiStage);\(fandomStage),建議改用批次貼上手動輸入"
                    }
                } catch {
                    isSearching = false
                    statusText = ""
                    errorText = "\(wikiStage);Fandom 查詢失敗:\(error.localizedDescription)"
                }
            } catch {
                isSearching = false
                statusText = ""
                errorText = "查詢失敗:\(error.localizedDescription)"
            }
        }
    }
}

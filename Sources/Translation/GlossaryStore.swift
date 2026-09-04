import Foundation

/// 一筆人名詞庫條目:使用者手動釘選的「原文 → 正確譯名」。
///
/// `original` 存的是**釘選當下的原始字串**(沒有正規化過),只作顯示用;
/// 真正用來比對的 key 是 `GlossaryStore.normalize(original)`,在記憶體裡
/// 另外建索引。這樣之後如果要調整比對規則,不用做任何資料遷移——下次啟動
/// 重新建索引就是新規則。
struct GlossaryEntry: Codable, Identifiable {
    let id: UUID
    var original: String
    var translated: String
    var createdAt: Date
}

/// 檔案格式的版本信封。現在用不到,但加一個 `version` 欄位的成本是零,
/// 之後真的要改格式時才有辦法分辨舊檔。
private struct GlossaryFile: Codable {
    var version: Int
    var entries: [GlossaryEntry]
}

/// 人名詞庫:使用者釘選一次正確譯名之後,之後每次遇到同一段原文都直接沿用,
/// 不再讓模型重新猜。
///
/// ⚠️ 2026-09-04:這個功能存在的理由——`NA MUGYEOM`(正確譯名「羅茂謙」)
/// 連續四輪 prompt 修法都翻不對(娜娜穆耶歐姆 → 나 → 娜娜穆根 → 南娜穆根,
/// 詳見 `notes/2026-09-03.md` 與 `VLMTranslationEngine.makeTextOnlyPrompt`
/// 的註解)。這不是措辭問題:羅馬拼音→漢字本質是「一對多查表」,不是推理
/// 算得出來的東西,4B 量化模型做不到。`makeTextOnlyPrompt` 註解最後一段
/// 早就寫下這個結論(沉浸式翻譯的 `{{terms_prompt}}` 就是這個機制),這次
/// 只是把它實作出來。
///
/// ⚠️ **強制力來自「在呼叫模型之前就攔截」,不是靠 prompt**。現有的
/// `context` 通道(`makeTextOnlyPrompt` 那段)明文寫「For reference only
/// ... these are NOT the text to translate now」,是建議性的,模型可以
/// 不理會。詞庫必須是權威性的,所以
/// `TranslationRequestCoordinator.runTranslation` 是在呼叫
/// `vlmEngine.translateText` **之前**查這個 store,命中就直接用釘選值、
/// 完全不跑推理(順帶還比較快)。
///
/// 這是這個專案第一個 `Codable` + JSON 持久化(全 repo 原本零前例)。
/// 檔案位置照 `LocalModelStore` 的 Application Support 慣例,但**刻意
/// 不設 `isExcludedFromBackup`**——模型權重是 2.2GB 可以重新下載的東西,
/// 詞庫是幾 KB 但無可取代的手動輸入資料,應該進 iCloud 備份。
@MainActor
final class GlossaryStore: ObservableObject {

    /// 新的在前(`upsert` 插在最前面),直接驅動詞庫清單 UI。
    @Published private(set) var entries: [GlossaryEntry] = []

    /// 載入/儲存失敗的訊息。**只在詞庫 sheet 裡顯示,絕不阻擋翻譯流程**——
    /// 詞庫壞掉頂多是「釘選失效」,不該讓整個閱讀功能停擺。
    @Published private(set) var lastError: String?

    /// `normalize(original)` → `translated`。衍生資料,不寫進檔案,
    /// 每次載入與異動後由 `rebuildIndex()` 重算。
    private var index: [String: String] = [:]

    private static let currentVersion = 1

    init() {
        load()
    }

    // MARK: - 查詢

    /// 翻譯前的攔截點。回傳非 nil 代表這段文字使用者釘過,直接用這個譯文。
    func lookup(_ text: String) -> String? {
        let key = Self.normalize(text)
        guard !key.isEmpty else { return nil }
        return index[key]
    }

    // MARK: - 異動

    /// 新增或覆蓋一筆。同一個正規化 key 只會有一筆(last-write-wins)——
    /// 留重複項只會讓清單看起來很混亂,而且使用者無從得知哪一筆生效。
    func upsert(original: String, translated: String) {
        let key = Self.normalize(original)
        let cleanTranslated = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !cleanTranslated.isEmpty else { return }

        if let existing = entries.firstIndex(where: { Self.normalize($0.original) == key }) {
            entries[existing].original = original
            entries[existing].translated = cleanTranslated
        } else {
            entries.insert(
                GlossaryEntry(
                    id: UUID(), original: original, translated: cleanTranslated,
                    createdAt: Date()),
                at: 0)
        }
        rebuildIndex()
        save()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        rebuildIndex()
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        rebuildIndex()
        save()
    }

    // MARK: - 正規化

    /// 釘選時與查詢時套用同一套規則,兩邊必須完全一致,不然會產生
    /// 「釘了卻永遠比對不到」的死條目。
    ///
    /// 1. NFC 正規化——原文來自兩個不同 OCR 引擎(`VNRecognizeTextRequest`
    ///    與 VisionKit `ImageAnalyzer`,見 `RegionMerger.TextRegion.bestText`),
    ///    兩者對 `É` 用組合還是分解形式不保證一致。
    /// 2. 連續空白/換行收成單一空格——`RegionMerger` 合併多行的結果,
    ///    換行位置每次可能不同。
    /// 3. 轉小寫——這類名字 OCR 多半全大寫但不保證,對中文目標語言而言
    ///    大小寫不帶意義。
    /// 4. 去除**頭尾**標點與空白——讓 `¡NA MUGYEOM!`、`NA MUGYEOM.`、
    ///    `NA MUGYEOM` 共用同一筆。
    ///
    /// ⚠️ **刻意保留中間的標點**:`¡UWA!` 跟 `UWA` 的差別對狀聲詞處理有
    /// 意義,而且清掉中間標點會提高不同句子誤撞同一個 key 的機率。釘選的
    /// 譯文是整塊取代,誤判會直接顯示在畫面上蓋掉不相干的對白,所以這裡
    /// 一律偏向「寧可漏抓,不要錯抓」。
    static func normalize(_ text: String) -> String {
        let collapsed = text
            .precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
        let trimSet = CharacterSet.punctuationCharacters
            .union(.whitespacesAndNewlines)
            .union(.symbols)
        return collapsed.trimmingCharacters(in: trimSet)
    }

    private func rebuildIndex() {
        var next: [String: String] = [:]
        for entry in entries {
            let key = Self.normalize(entry.original)
            guard !key.isEmpty else { continue }
            // `entries` 是新的在前,而 `upsert` 已保證同 key 不重複;
            // 萬一手動編過檔案造成重複,以比較新的那筆(排在前面)為準。
            if next[key] == nil {
                next[key] = entry.translated
            }
        }
        index = next
    }

    // MARK: - 持久化

    static var directoryURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Glossary", isDirectory: true)
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent("glossary.json")
    }

    /// 檔案不存在是正常的首次啟動狀態,不是錯誤。
    ///
    /// 解碼失敗時**不刪除也不覆寫檔案**——之後真的有成功的 `save()` 才會
    /// 蓋掉它,而那只發生在使用者主動釘選之後,等於損失是使用者自己觸發的。
    private func load() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(GlossaryFile.self, from: data)
            entries = decoded.entries
            rebuildIndex()
        } catch {
            lastError = "詞庫讀取失敗:\(error.localizedDescription)"
        }
    }

    /// ⚠️ 整段包在 `do/catch` 裡,任何失敗只寫進 `lastError`。這個專案有
    /// `EXC_BREAKPOINT`/`SIGTRAP` 這類**接不住**的當機紀錄(見
    /// `notes/2026-09-02.md` 的 LFM2.5 事故),而且裝置上沒有除錯器,
    /// 所以這裡一律禁用 `try!`、強制解包、`fatalError`。
    ///
    /// 主執行緒同步 I/O 是刻意的:資料只有幾 KB,而這個 class 跟
    /// `TranslationRequestCoordinator` 一樣是 `@MainActor`。**不要為了
    /// 「正確性」把它改成 actor/async**——這個專案每次增加並行邊界都生出
    /// 只在裝置上出現的當機(見 09-02 的 Metal 競態事故)。
    private func save() {
        do {
            let dir = Self.directoryURL
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                GlossaryFile(version: Self.currentVersion, entries: entries))
            try data.write(to: Self.fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "詞庫儲存失敗:\(error.localizedDescription)"
        }
    }
}

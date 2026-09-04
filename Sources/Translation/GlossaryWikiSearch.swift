import Foundation

/// 詞庫「自動查找」的查找結果:找到的中文維基條目網址與純文字內容,
/// 交給下一步(`VLMTranslationEngine.extractGlossaryCandidates`)抽取人名。
struct GlossaryWikiSearchResult {
    let sourceTitle: String
    let zhArticleURL: URL
    let zhArticleText: String
}

/// `stage` 帶著「查到哪一步找不到」,方便 UI 顯示對應訊息,不是只講
/// 「失敗」兩個字讓使用者猜。
enum GlossaryWikiSearchError: Error {
    case notFound(stage: String)
}

/// 純網路查找,不碰任何 AI 推理——這個檔案只負責「找到中文維基條目的
/// 純文字內容」,抽取人名是下一步的事。
///
/// ⚠️ 2026-09-04:設計時查證過兩件事,都不是憑印象:
/// 1. 維基百科的搜尋→跨語言連結(langlinks)→條目內文,三個 API 呼叫
///    用真實請求測過完整鏈路可行(用「Solo Leveling」測到 `pageid`、
///    langlinks 正確回傳「我獨自升級」、中文維基 extract 正確回傳內文)。
///    用 `langlinks` 直接拿對應語言的條目,不用先解析出韓文/日文名再
///    重新搜尋一次——維基百科本來就有這個跨語言對照,沒有理由不用。
/// 2. 原本規劃「維基百科查不到就退回 Fandom wiki」,實測 Fandom 的跨 wiki
///    搜尋 API(`www.fandom.com/api/v1/Search/CrossWiki`)回傳 HTTP 403,
///    是 Cloudflare 的機器人防護頁,不是網址打錯——這條備援拿掉了,詳見
///    `notes/`。v1 只做維基百科這一層,查不到就是查不到,不做「猜 wiki
///    子網域」這種不可靠的替代方案。
enum GlossaryWikiSearch {

    /// 抽取步驟送進 LLM 的內文長度上限——wiki 全文常常有幾萬字,遠超過
    /// 這顆量化模型能穩定處理的長度。這個數字是起手估計值,沒有裝機驗證
    /// 過,需要下一輪測試校正(太短可能漏掉角色列表段落,太長會拖垮生成
    /// 穩定度,這正是純文字模式一路走來反覆踩到的雷)。
    static let maxExtractCharacters = 6000

    private struct SearchResponse: Decodable {
        struct QueryResult: Decodable {
            struct Item: Decodable {
                let pageid: Int
                let title: String
            }
            let search: [Item]
        }
        let query: QueryResult
    }

    private struct CategoriesResponse: Decodable {
        struct Page: Decodable {
            struct Category: Decodable {
                let title: String
            }
            let categories: [Category]?
        }
        struct QueryResult: Decodable {
            let pages: [String: Page]
        }
        let query: QueryResult
    }

    private struct LangLinksResponse: Decodable {
        struct Page: Decodable {
            struct LangLink: Decodable {
                let lang: String
                let value: String
                enum CodingKeys: String, CodingKey {
                    case lang
                    case value = "*"
                }
            }
            let langlinks: [LangLink]?
        }
        struct QueryResult: Decodable {
            let pages: [String: Page]
        }
        let query: QueryResult
    }

    private struct ExtractResponse: Decodable {
        struct Page: Decodable {
            let title: String
            let extract: String?
        }
        struct QueryResult: Decodable {
            let pages: [String: Page]
        }
        let query: QueryResult
    }

    /// App 的語言代碼(`languageOptions`,見 `MangaReaderView.swift`)不完全
    /// 等於維基百科的子網域代碼——只有 `zh-Hans`/`zh-Hant-TW` 這兩個需要
    /// 轉換,其他(es/en/ja/ko/fr/de)剛好一致。
    private static func wikipediaLanguageCode(for appLanguageCode: String) -> String {
        switch appLanguageCode {
        case "zh-Hans", "zh-Hant-TW": return "zh"
        default: return appLanguageCode
        }
    }

    static func search(
        seriesTitle: String, sourceLanguageCode: String,
        onProgress: @escaping (String) -> Void
    ) async throws -> GlossaryWikiSearchResult {
        let trimmedTitle = seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw GlossaryWikiSearchError.notFound(stage: "作品名稱是空的")
        }

        let session = URLSession(configuration: .ephemeral)
        let sourceLang = wikipediaLanguageCode(for: sourceLanguageCode)
        // 查過哪些語言都記下來——之前只顯示「維基百科查不到這部作品」,
        // 使用者沒辦法從畫面上分辨「有沒有真的查過來源語言」,查詢過程的
        // 狀態文字跑完就被最終結果蓋掉了。把查過的語言列進失敗訊息裡,
        // 不需要另外問。
        var triedLanguages: [String] = []

        onProgress("查詢\(sourceLang)維基百科…")
        triedLanguages.append(sourceLang)
        var found = try await searchWikipedia(language: sourceLang, title: trimmedTitle, session: session)

        if found == nil, sourceLang != "en" {
            onProgress("查詢英文維基百科…")
            triedLanguages.append("en")
            found = try await searchWikipedia(language: "en", title: trimmedTitle, session: session)
        }

        guard let (pageID, foundLanguage, foundTitle) = found else {
            let languagesText = triedLanguages.joined(separator: "、")
            let suffix = triedLanguages.count > 1 ? "都查不到" : "查不到"
            throw GlossaryWikiSearchError.notFound(stage: "\(languagesText)維基百科\(suffix)這部作品")
        }

        onProgress("查詢中文對照條目…")
        guard let zhTitle = try await fetchZhTitle(forPageID: pageID, language: foundLanguage, session: session)
        else {
            throw GlossaryWikiSearchError.notFound(stage: "找到條目「\(foundTitle)」,但沒有中文版本")
        }

        onProgress("下載中文條目內容…")
        guard let (url, text) = try await fetchExtract(zhTitle: zhTitle, session: session), !text.isEmpty
        else {
            throw GlossaryWikiSearchError.notFound(stage: "中文條目「\(zhTitle)」內容是空的")
        }

        return GlossaryWikiSearchResult(sourceTitle: foundTitle, zhArticleURL: url, zhArticleText: text)
    }

    /// 回傳 `nil` 代表「這個語言版本查不到,可以換下一個語言再試」——不是
    /// 錯誤,是預期中會發生的正常情況,呼叫端據此決定要不要 fallback。
    ///
    /// ⚠️ 2026-09-04:裝機實測抓到誤判——搜尋「El matón a cargo」,維基百科
    /// 的 `list=search` 回傳的第一筆是「Marco Pomponio Matón」(古羅馬政治
    /// 家),純粹是關鍵字「Matón」剛好重疊,跟這部漫畫毫無關係。原本的寫法
    /// 無條件信任第一筆結果,沒有檢查回傳結果跟查詢字串到底像不像——維基
    /// 百科的全文搜尋是相關性排序,不是「有沒有這個條目」的精確比對,排第
    /// 一不代表真的是同一個作品。加兩層過濾,兩層都用真實請求驗證過對這個
    /// 假陽性案例確實有效:
    /// 1. `isPlausibleTitleMatch`——查詢字串裡「有意義的字」要全部出現在
    ///    候選標題裡(這個案例候選標題沒有「cargo」,直接被排除)
    /// 2. **分類檢查**——用 `prop=categories` 確認候選條目的分類裡有沒有
    ///    manga/manhwa/webtoon/comic 這類字眼(這個案例的分類全是古羅馬
    ///    歷史相關,`Categoría:Cónsules de la República romana` 之類,
    ///    完全沒有漫畫相關分類,同樣會被排除)。兩層都通過才接受,都不符合
    ///    就當作這個語言版本查不到——寧可少抓、不要抓錯(跟詞庫比對「寧可
    ///    漏抓不要錯抓」是同一個原則)。
    private static func searchWikipedia(
        language: String, title: String, session: URLSession
    ) async throws -> (pageID: Int, language: String, title: String)? {
        var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: title),
            URLQueryItem(name: "srlimit", value: "5"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return nil }

        let plausible = decoded.query.search.filter { isPlausibleTitleMatch(query: title, candidate: $0.title) }
        guard !plausible.isEmpty else { return nil }

        let comicPageIDs = await comicRelatedPageIDs(
            among: plausible.map(\.pageid), language: language, session: session)
        guard let match = plausible.first(where: { comicPageIDs.contains($0.pageid) }) else { return nil }
        return (match.pageid, language, match.title)
    }

    /// 判斷候選條目標題跟查詢字串是不是「同一個東西」——要求查詢字串裡
    /// 「有意義的字」(去掉常見的冠詞/介詞、長度太短的字)全部都要出現在
    /// 候選標題的字集合裡。用「全部要有」而不是設一個模糊的相似度門檻
    /// (例如 Dice 係數),是因為算過「El matón a cargo」跟「Marco Pomponio
    /// Matón」這組錯誤配對,字元層級的相似度其實有 0.3 左右,跟真正配對
    /// 成功案例的門檻太接近,容易誤判;字詞層級「全部要有」對這個案例能
    /// 正確排除(候選標題沒有「cargo」這個字),對真正相關的條目(標題
    /// 用詞通常包含查詢的核心字)還是能通過。
    private static func isPlausibleTitleMatch(query: String, candidate: String) -> Bool {
        let queryWords = significantWords(in: query)
        guard !queryWords.isEmpty else { return false }
        let candidateWords = significantWords(in: candidate)
        return queryWords.isSubset(of: candidateWords)
    }

    private static let comicCategoryKeywords = [
        "manga", "manhwa", "manhua", "webtoon", "comic", "historieta"
    ]

    /// 一次查詢一批候選 pageid 的分類(用 `|` 合併,避免逐筆各打一次 API),
    /// 回傳分類裡有出現漫畫相關字眼的那些 pageid。用真實請求驗證過:
    /// 「Solo Leveling」的分類裡有「2010s manhwa」「Action webtoons」這類
    /// 字眼會通過;「Marco Pomponio Matón」的分類全是古羅馬歷史相關,不會
    /// 通過。查詢失敗(逾時、格式跑掉)一律回傳空集合,不阻擋、不當機。
    private static func comicRelatedPageIDs(
        among pageIDs: [Int], language: String, session: URLSession
    ) async -> Set<Int> {
        guard !pageIDs.isEmpty else { return [] }
        var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "categories"),
            URLQueryItem(name: "pageids", value: pageIDs.map(String.init).joined(separator: "|")),
            URLQueryItem(name: "cllimit", value: "50"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        guard let (data, _) = try? await session.data(for: request),
              let decoded = try? JSONDecoder().decode(CategoriesResponse.self, from: data)
        else { return [] }

        var matched: Set<Int> = []
        for (key, page) in decoded.query.pages {
            guard let pageID = Int(key) else { continue }
            let categoryTitles = (page.categories ?? []).map { $0.title.lowercased() }
            let isComic = categoryTitles.contains { title in
                comicCategoryKeywords.contains { title.contains($0) }
            }
            if isComic { matched.insert(pageID) }
        }
        return matched
    }

    private static let titleStopwords: Set<String> = [
        "el", "la", "los", "las", "de", "del", "a", "un", "una", "unos", "unas",
        "the", "of", "and", "in", "on", "at", "to", "for", "por", "en", "y"
    ]

    private static func significantWords(in text: String) -> Set<String> {
        let folded = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return Set(
            folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { $0.lowercased() }
                .filter { $0.count >= 3 && !titleStopwords.contains($0) })
    }

    /// 回傳 `nil` 代表這個條目沒有中文版——同樣不是錯誤。
    private static func fetchZhTitle(
        forPageID pageID: Int, language: String, session: URLSession
    ) async throws -> String? {
        var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "langlinks"),
            URLQueryItem(name: "lllang", value: "zh"),
            URLQueryItem(name: "pageids", value: String(pageID)),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(LangLinksResponse.self, from: data),
              let page = decoded.query.pages.values.first,
              let langlink = page.langlinks?.first
        else { return nil }
        return langlink.value
    }

    private static func fetchExtract(
        zhTitle: String, session: URLSession
    ) async throws -> (url: URL, text: String)? {
        var components = URLComponents(string: "https://zh.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "extracts"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "titles", value: zhTitle),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let apiURL = components.url else { return nil }
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 15

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(ExtractResponse.self, from: data),
              let page = decoded.query.pages.values.first,
              let extract = page.extract, !extract.isEmpty
        else { return nil }

        // 給使用者看的可讀網址(不是實際發送請求用的 API 網址)——讓
        // `GlossarySearchSheet` 能提供一個「自己去核對來源」的連結,自動
        // 抽取的結果不該是黑盒子。
        let encodedTitle = zhTitle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? zhTitle
        let readableURL = URL(string: "https://zh.wikipedia.org/wiki/\(encodedTitle)") ?? apiURL

        let truncated = String(extract.prefix(maxExtractCharacters))
        return (readableURL, truncated)
    }
}

/// 詞庫「自動查找」的 Fandom 備援結果——找到的 wiki 網址跟角色名單
/// (**英文原文,不是中文**)。交給 `VLMTranslationEngine.
/// transliterateNameList` 生成中文候選——那一步是**生成,不是查表**,
/// 可靠度天生比 `GlossaryWikiSearch`(維基百科中文條目是查表結果)低,
/// UI 必須清楚標示,不能讓使用者誤以為兩種來源品質一樣。
struct GlossaryFandomSearchResult {
    let wikiTitle: String
    let wikiURL: URL
    let characterNames: [String]
}

/// 只在維基百科查不到時才呼叫(見 `GlossarySearchSheet.search`)。
///
/// ⚠️ 2026-09-04:起因——`Designated Bully`(= 西班牙文版「El matón a
/// cargo」)維基百科完全沒有條目(英文、西班牙文、韓文羅馬拼音三種標題
/// 都用 `curl` 查證過,見 `notes/`),但確實有專屬 Fandom wiki
/// (`designated-bully.fandom.com`),裡面有結構清楚的「Characters」分類,
/// 角色名單(`Kwon Daegun`、`Park Heejun` 等)跟實際 OCR 拼法對得上。
///
/// **不走 Fandom 的跨 wiki 搜尋 API**——那個已經證實會被 Cloudflare 擋
/// (HTTP 403,見 `GlossaryWikiSearch` 的說明)。改用**猜網域規則**:
/// Fandom wiki 網域慣例就是標題轉小寫、空白換連字號,「Designated
/// Bully」→`designated-bully`,剛好就是真實網址。這不是網路搜尋,是
/// 確定性的字串轉換 + 直接打對那個網域自己的 `api.php`(已驗證這條路
/// 沒被擋)——**代價是需要使用者自己輸入正確的英文標題,猜錯 slug 就是
/// 猜不到,不會有第二層備援去找正確 slug**。
enum GlossaryFandomSearch {

    private struct SiteInfoResponse: Decodable {
        struct Query: Decodable {
            struct General: Decodable {
                let sitename: String
            }
            let general: General
        }
        let query: Query
    }

    private struct CategoryMembersResponse: Decodable {
        struct Query: Decodable {
            struct Member: Decodable {
                let title: String
                let ns: Int
            }
            let categorymembers: [Member]
        }
        let query: Query
    }

    /// 依序嘗試的分類名稱——「Characters」最常見,「Main Characters」是
    /// 備用(這個測試 wiki 兩個分類都有,但只有前者抓到完整名單)。
    private static let characterCategoryNames = ["Characters", "Main Characters"]

    static func search(seriesTitle: String) async throws -> GlossaryFandomSearchResult {
        let slug = slugify(seriesTitle)
        guard !slug.isEmpty else {
            throw GlossaryWikiSearchError.notFound(stage: "作品名稱是空的,無法猜測 Fandom 網域")
        }

        let session = URLSession(configuration: .ephemeral)

        guard let siteName = try await fetchSiteName(slug: slug, session: session) else {
            throw GlossaryWikiSearchError.notFound(
                stage: "猜測的 Fandom 網域「\(slug).fandom.com」不存在(這是猜測,不是保證,可能是這個系列沒有專屬 wiki,或標題跟 wiki 網域命名不一致)")
        }

        var names: [String] = []
        for category in characterCategoryNames {
            names = try await fetchCategoryMemberTitles(slug: slug, category: category, session: session)
            if !names.isEmpty { break }
        }
        guard !names.isEmpty else {
            throw GlossaryWikiSearchError.notFound(
                stage: "找到 Fandom wiki「\(siteName)」,但沒有找到角色分類頁面")
        }

        let wikiURL = URL(string: "https://\(slug).fandom.com/wiki/\(siteName.replacingOccurrences(of: " ", with: "_"))")
            ?? URL(string: "https://\(slug).fandom.com")!

        return GlossaryFandomSearchResult(
            wikiTitle: siteName, wikiURL: wikiURL, characterNames: Array(Set(names)).sorted())
    }

    /// 把作品名稱轉成 Fandom 網域慣用的 slug——小寫、非英數字元收成單一
    /// 連字號,頭尾不留連字號。用真實案例驗證過:「Designated Bully」→
    /// `designated-bully`,「Solo Leveling」→`solo-leveling`,都是真實
    /// 存在的 Fandom 網域。
    static func slugify(_ title: String) -> String {
        let folded = title.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var result = ""
        var lastWasHyphen = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        if result.hasSuffix("-") { result.removeLast() }
        return result.lowercased()
    }

    /// 用 `meta=siteinfo` 確認猜的網域真的存在——這是最輕量的存在性檢查,
    /// 不假設任何特定分類/頁面一定存在。
    private static func fetchSiteName(slug: String, session: URLSession) async throws -> String? {
        var components = URLComponents(string: "https://\(slug).fandom.com/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "meta", value: "siteinfo"),
            URLQueryItem(name: "siprop", value: "general"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        guard let (data, _) = try? await session.data(for: request),
              let decoded = try? JSONDecoder().decode(SiteInfoResponse.self, from: data)
        else { return nil }
        return decoded.query.general.sitename
    }

    /// 只留一般條目(`ns == 0`),排除子分類本身(`Category:Main
    /// Characters` 這種 `ns == 14` 的項目,已經在裝機前用真實請求確認過
    /// 這個測試 wiki 的 `Category:Characters` 底下混了一個子分類進來)。
    private static func fetchCategoryMemberTitles(
        slug: String, category: String, session: URLSession
    ) async throws -> [String] {
        var components = URLComponents(string: "https://\(slug).fandom.com/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "categorymembers"),
            URLQueryItem(name: "cmtitle", value: "Category:\(category)"),
            URLQueryItem(name: "cmlimit", value: "50"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        guard let (data, _) = try? await session.data(for: request),
              let decoded = try? JSONDecoder().decode(CategoryMembersResponse.self, from: data)
        else { return [] }
        return decoded.query.categorymembers.filter { $0.ns == 0 }.map(\.title)
    }
}

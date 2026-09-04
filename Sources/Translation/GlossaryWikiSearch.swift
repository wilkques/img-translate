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

        onProgress("查詢\(sourceLang)維基百科…")
        var found = try await searchWikipedia(language: sourceLang, title: trimmedTitle, session: session)

        if found == nil, sourceLang != "en" {
            onProgress("查詢英文維基百科…")
            found = try await searchWikipedia(language: "en", title: trimmedTitle, session: session)
        }

        guard let (pageID, foundLanguage, foundTitle) = found else {
            throw GlossaryWikiSearchError.notFound(stage: "維基百科查不到這部作品")
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
    private static func searchWikipedia(
        language: String, title: String, session: URLSession
    ) async throws -> (pageID: Int, language: String, title: String)? {
        var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: title),
            URLQueryItem(name: "srlimit", value: "1"),
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
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data),
              let first = decoded.query.search.first
        else { return nil }
        return (first.pageid, language, first.title)
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

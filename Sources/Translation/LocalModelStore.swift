import Foundation
import HuggingFace
import MLXLMCommon

/// 本機模型檔案的落地位置與 HubClient 設定。
///
/// 為什麼是 Application Support 而不是 Caches:
/// - `Caches` 在磁碟空間吃緊時「會被 iOS 清掉」,2.2GB 的模型被清掉等於白下載一次。
/// - LiveContainer 會把 `NSHomeDirectory()` 導向 guest app 自己的 container,
///   container 和 bundle 在 LiveContainer 是分開管理的,重新匯入新版 ipa
///   不會清掉這裡的檔案(除非在 LiveContainer 裡對這個 container 執行
///   Delete Data / Remove Container)。
enum LocalModelStore {

    static var modelsDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HuggingFaceModels", isDirectory: true)
    }

    /// 建立目錄並標記不進 iCloud 備份(2.2GB 進備份會很慘)。
    @discardableResult
    static func prepareDirectory() throws -> URL {
        var dir = modelsDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// ⚠️ 2026-09-02:2026-09-01 曾經改用背景 `URLSession`(見 git 歷史
    /// `5b40b98`),想讓模型下載撐過「app 被切到背景/鎖螢幕」。裝機實測
    /// 崩潰,confirmed 是當時筆記預告的三種風險之一(c):`HubClient` 內部用
    /// 了完成處理常式(completion handler)風格的 API,iOS 明確禁止在背景
    /// `URLSessionConfiguration` 上使用這種 API,直接丟例外——
    /// 「Completion handler blocks are not supported in background
    /// sessions. Use a delegate instead.」。錯誤在 `HubClient`
    /// (`swift-huggingface`)套件內部,不是我們的程式碼能修的,照筆記當時
    /// 定的應變方案:**改回一般 session,不追求真正的背景下載**,只在呼叫端
    /// (`VLMTranslationEngine.ensureLoaded()`/
    /// `LocalLLMTranslationEngine` 對應方法)用 `beginBackgroundTask`
    /// 延長切背景瞬間的前景執行時間,不是解法而是緩解——使用者中途切背景,
    /// 下載仍然可能中斷,但至少不會直接崩潰。
    ///
    /// `purpose` 保留參數(雖然不再用來組 session identifier)是為了不動
    /// 呼叫端簽名,`VLMTranslationEngine`/`LocalLLMTranslationEngine` 都不用
    /// 跟著改。
    static func makeHubClient(purpose: String) throws -> HubClient {
        let dir = try prepareDirectory()

        // waitsForConnectivity:沒網路時等待而不是立刻失敗;
        // timeoutIntervalForResource 放大到 2 小時,避免大檔下載被整體逾時砍掉。
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 2
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true

        return HubClient(
            session: URLSession(configuration: configuration),
            userAgent: "ImgTranslate/1.0",
            cache: HubCache(cacheDirectory: dir)
        )
    }

    /// 下載前先檢查剩餘空間,免得下到一半才爆。
    static func availableBytesForImportantUsage() -> Int64? {
        let url = modelsDirectory
        return try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
    }

    static func isModelPresent() -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory, includingPropertiesForKeys: nil) else { return false }
        return !contents.isEmpty
    }

    /// `HubCache` 用跟 Python `huggingface_hub` 相容的快取結構:每個 repo 一個
    /// `models--{org}--{repo}` 資料夾,底下有 `snapshots/`(下載完成才會有東西)。
    /// 這裡直接照這個命名規則找,不透過 `HubClient` 額外發任何網路請求。
    private static func repoDirectory(for repoId: String) -> URL {
        modelsDirectory.appendingPathComponent(
            "models--" + repoId.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    /// 判斷某個模型的權重是否已經下載到本機快取(給「下載/移除」按鈕判斷要顯示
    /// 哪一種)。`ModelConfiguration.id` 是 `.id(String, revision: String)`
    /// (HuggingFace repo,裝機編譯才發現實際帶兩個關聯值,不是單一 String)或
    /// `.directory(URL)`(本機路徑)兩種,只有前者需要、也才能查快取,revision
    /// 這裡用不到。
    static func isModelDownloaded(_ configuration: ModelConfiguration) -> Bool {
        guard case .id(let repoId, revision: _) = configuration.id else { return false }
        let snapshotsDir = repoDirectory(for: repoId).appendingPathComponent("snapshots")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: snapshotsDir, includingPropertiesForKeys: nil) else { return false }
        return !contents.isEmpty
    }

    /// 下載前先問一次 Hugging Face API,確認這個 repo 真的存在。
    ///
    /// ⚠️ 2026-09-02 事故後補的防護:選單裡放了一個「照命名慣例猜的」repo id
    /// (`LiquidAI/LFM2.5-VL-3B-MLX-4bit`,事後查證根本沒有這個 repo),裝機
    /// 選下去**直接閃退**(`EXC_BREAKPOINT`/`SIGTRAP`,Swift 執行期 trap,
    /// 沒辦法用 `try/catch` 接住)。有了這個檢查,同樣的情況會變成畫面上一行
    /// 「找不到這個模型」的紅字,不會再整個 App 死掉。
    ///
    /// 兩個刻意的設計:
    /// - **已經下載過就跳過檢查**:離線也要能用已經抓好的模型,不能因為連不上
    ///   Hugging Face 就擋住。
    /// - **只有明確的 404 才擋**:逾時、沒網路、DNS 失敗這些一律放行,讓後續
    ///   真正的下載流程自己去處理——網路不穩不該被誤判成「模型不存在」。
    static func verifyRepositoryExists(_ configuration: ModelConfiguration) async throws {
        guard case .id(let repoId, revision: _) = configuration.id else { return }
        if isModelDownloaded(configuration) { return }
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoId)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15

        let statusCode: Int
        do {
            let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return   // 網路層失敗不擋,交給後續下載流程處理
        }
        if statusCode == 404 {
            throw HubDownloadError.repositoryNotFound(repoId)
        }
    }

    /// 某顆模型目前在本機快取目錄裡實際佔用的位元組數。
    ///
    /// ⚠️ 2026-09-02 新增:下載進度百分比原本完全依賴上游 `HubClient` 的
    /// `progressHandler`,裝機實測**百分比從頭到尾不會動**(下載本身有在跑,
    /// 只是進度沒回報)。沒辦法讀 `swift-huggingface` 的原始碼確認它為什麼不
    /// 回報、也沒有本機編譯器可以實驗,與其瞎猜,不如換一個不依賴上游行為的
    /// 做法:直接掃硬碟看檔案長多大,自己除以預估總大小算進度。
    ///
    /// 掃整個 repo 目錄(含 `blobs/` 底下下載中的暫存檔),只計 regular file
    /// ——`snapshots/` 裡是指向 `blobs/` 的 symlink,不算 regular file,所以
    /// 不會重複計算同一份資料。
    ///
    /// ⚠️ 2026-09-03 裝機實測發現:進度會卡在 0% 直到下載快完成才突然跳動。
    /// 根因是原本傳了 `options: [.skipsHiddenFiles]`——下載中的暫存檔很可能
    /// 用點開頭命名(常見的 `.incomplete`/隱藏暫存檔慣例),被這個選項整段
    /// 跳過不算,等到暫存檔下載完成、被改名/搬進最終的非隱藏檔名時才會
    /// 突然被算到。既然這個函式本來就是為了抓「下載中的暫存檔」才寫的(見
    /// 上面的說明),跳過隱藏檔正好跟目的相反,改成不跳過。
    static func downloadedBytes(_ configuration: ModelConfiguration) -> Int64 {
        guard case .id(let repoId, revision: _) = configuration.id else { return 0 }
        let root = repoDirectory(for: repoId)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true,
                let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// 砍掉某個模型在本機快取裡的整個 repo 資料夾,釋放空間。呼叫端要自己先確認
    /// 這顆模型目前沒有被載入使用中(`VLMTranslationEngine.removeDownload(of:)`
    /// 會先 `unload()` 再呼叫這個)。
    static func removeModel(_ configuration: ModelConfiguration) throws {
        guard case .id(let repoId, revision: _) = configuration.id else { return }
        try FileManager.default.removeItem(at: repoDirectory(for: repoId))
    }
}

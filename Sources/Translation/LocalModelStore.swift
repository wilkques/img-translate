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

    static func makeHubClient() throws -> HubClient {
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

    /// 砍掉某個模型在本機快取裡的整個 repo 資料夾,釋放空間。呼叫端要自己先確認
    /// 這顆模型目前沒有被載入使用中(`VLMTranslationEngine.removeDownload(of:)`
    /// 會先 `unload()` 再呼叫這個)。
    static func removeModel(_ configuration: ModelConfiguration) throws {
        guard case .id(let repoId, revision: _) = configuration.id else { return }
        try FileManager.default.removeItem(at: repoDirectory(for: repoId))
    }
}

import Foundation
import HuggingFace

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
}

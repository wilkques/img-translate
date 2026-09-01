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

    /// ⚠️ 2026-09-01:改用背景 `URLSession`,讓下載能撐過「app 被切到背景/
    /// 鎖螢幕」——這是目前為止唯一沒辦法在裝機前確認會不會生效的改動:
    /// `HubClient`(`swift-huggingface`)拿到這個 session 之後內部到底怎麼用
    /// 無法從原始碼確認,理論上有三種結果:(a) 真的沿用背景 session,下載撐
    /// 得過去;(b) 內部另外建立自己的 session,這個設定沒被用到;(c) 內部用
    /// `session.data(for:)`/`download(for:)` 這類 async 便利方法對背景
    /// session 呼叫會直接丟例外崩潰,而且編譯抓不到。裝機下載到一半切背景
    /// 測過才知道是哪一種——這輪範圍只保證「切背景/鎖螢幕但沒被強制關閉」,
    /// 使用者從切換器滑掉或系統記憶體壓力砍掉 process 這種更極端的情境,
    /// `HubClient` 沒有公開的「重新接上一半下載」API,不在這輪範圍內。
    ///
    /// `purpose` 帶進 session identifier 裡,只是為了讓 `VLMTranslationEngine`
    /// 跟 `LocalLLMTranslationEngine` 兩邊各自呼叫這個函式時不要撞成同一個
    /// identifier——背景 session 的 identifier 同一時間只能對應一個活躍
    /// session,兩顆引擎理論上不會同時下載(`ContentView` 切引擎時會
    /// `unload()` 沒在用的那個),但沒有壞處,順手避開。
    static func makeHubClient(purpose: String) throws -> HubClient {
        let dir = try prepareDirectory()

        // waitsForConnectivity:沒網路時等待而不是立刻失敗;
        // timeoutIntervalForResource 放大到 2 小時,避免大檔下載被整體逾時砍掉。
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "dev.cyril.imgtranslate.modeldownload.\(purpose)")
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 2
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false   // 使用者主動按下載,不要讓系統自己挑時機才開始

        return HubClient(
            session: URLSession(
                configuration: configuration,
                delegate: BackgroundSessionDelegate(),
                delegateQueue: nil
            ),
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

/// 只負責滿足背景 session 的生命週期合約——收到「這個 session 的所有背景
/// 事件都處理完了」通知,呼叫系統要求的 completion handler(`AppDelegate`
/// 存起來的那個)。真正的下載進度/完成邏輯已經在 `HubClient` 內部處理,這裡
/// 不重複實作,也不試圖攔截/重新實作下載本身。
final class BackgroundSessionDelegate: NSObject, URLSessionDelegate {
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            AppDelegate.backgroundSessionCompletionHandler?()
            AppDelegate.backgroundSessionCompletionHandler = nil
        }
    }
}

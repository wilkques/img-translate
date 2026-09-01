import UIKit

/// 補上背景下載(VLM 模型權重,2-3.5GB)需要的系統掛勾。
///
/// 背景 `URLSession` 的下載如果在 app 完全被系統喚醒前就已經在背景完成,
/// iOS 可能會重新啟動 app(不是恢復原本的 async 呼叫鏈,那條已經隨 process
/// 消失了)去呼叫這個方法——這是背景 session 生命週期合約要求的,不接住的話
/// 系統會認為 app 沒有正確處理背景事件。真正的下載進度/完成邏輯已經在
/// `HubClient`(`LocalModelStore.makeHubClient()`)內部處理,這裡只負責把
/// 系統要求的 completion handler 存起來,交給 `BackgroundSessionDelegate`
/// 在 `urlSessionDidFinishEvents(forBackgroundURLSession:)` 呼叫。
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundSessionCompletionHandler: (() -> Void)?

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Self.backgroundSessionCompletionHandler = completionHandler
    }
}

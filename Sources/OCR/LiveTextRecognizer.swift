import VisionKit
import UIKit

/// 2026-09-04:Safari 的「即時文字辨識」用的是 VisionKit 的 `ImageAnalyzer`,
/// 跟我們原本用的 Vision `VNRecognizeTextRequest` 是兩顆不同的引擎——查證
/// 過 Apple 開發者論壇多篇討論,確認 `ImageAnalyzer` 文字辨識品質較高但
/// **不提供文字座標**,`VNRecognizeTextRequest` 有座標但品質較差,官方沒有
/// 「兩者兼具」的 API。裝機反覆驗證過調 Vision 的各種設定(`revision`、
/// `usesLanguageCorrection`、`automaticallyDetectsLanguage`)都無法解決這個
/// 字體的 U/L 誤讀(`MUGYEOM` 被讀成 `MLGYEOM`),原因就是根本是不同引擎。
///
/// 這裡只負責「讀文字內容」,位置繼續完全依賴 Vision 的 bounding box——
/// 呼叫端(`TranslationRequestCoordinator`)要自己把這裡回傳的整頁文字行
/// 用相似度配對回 Vision 的區塊上。
///
/// ⚠️ 2026-09-07:回傳值語意——`nil` = 功能不支援/逾時/丟例外(異常狀態);
/// `[]`(非 nil 空陣列)= 正常跑完但這頁真的沒讀到任何一行文字;非空陣列 =
/// 讀到的文字行。09-04 首次寫這支時沒有區分「跑完沒結果」跟「跑不動」,
/// 兩者都回 `nil`——當時唯一呼叫端(純文字模式的整頁配對)兩者都當 no-op
/// 處理,分不分都不影響行為。09-07 新增的「Vision 完全沒抓到框」診斷需要
/// 分清楚這兩種情況(這頁真的沒字 vs 這次呼叫本身失敗/逾時),改成不把
/// 「空結果」跟「錯誤/逾時」混在一起回 `nil`。既有呼叫端是
/// `if let lines = ... { for l in lines ... }` 這種寫法,`[]` 一樣是
/// no-op,不影響既有行為。
enum LiveTextRecognizer {
    /// ⚠️ 這個專案已經踩過 Apple 系統 Translation framework 在 LiveContainer
    /// 側載環境下**靜默卡死、不拋錯也不完成**的坑(見 README「已知風險」)。
    /// VisionKit 有沒有同樣問題完全未知,裝機驗證前不能排除。
    ///
    /// 這裡刻意**不用** `withTaskGroup`(結構化並行)做逾時——結構化並行的
    /// 保證是「所有子工作都做完(或至少回應取消)才會返回」,如果
    /// `ImageAnalyzer.analyze` 真的跟 Translation framework 一樣完全不理會
    /// 取消訊號、直接卡死不動,`withTaskGroup` 還是會卡在那裡等,逾時保護
    /// 形同虛設。改用 `withCheckedContinuation` + 兩個**不受結構化並行約束**
    /// 的獨立 `Task`:誰先呼叫 `resume` 誰就決定結果,卡住的那個工作即使
    /// 之後才回來也只是被忽略(用鎖擋掉重複 resume),不會拖住呼叫端。
    static func recognizeLines(in image: UIImage, timeout: TimeInterval = 10) async -> [String]? {
        guard ImageAnalyzer.isSupported else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<[String]?, Never>) in
            let lock = NSLock()
            var didResume = false
            func resumeOnce(_ value: [String]?) {
                lock.lock()
                let shouldResume = !didResume
                didResume = true
                lock.unlock()
                guard shouldResume else { return }
                continuation.resume(returning: value)
            }

            Task {
                do {
                    let analyzer = ImageAnalyzer()
                    let configuration = ImageAnalyzer.Configuration([.text])
                    let analysis = try await analyzer.analyze(image, configuration: configuration)
                    let lines = analysis.transcript
                        .split(separator: "\n", omittingEmptySubsequences: true)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    resumeOnce(lines)
                } catch {
                    resumeOnce(nil)
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                resumeOnce(nil)
            }
        }
    }
}

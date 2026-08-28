import Foundation
import Translation
import SwiftUI

/// ⚠️ 這是這次最沒把握的一塊,寫進 README 的待驗證項目:
/// 1. Translation framework 的公開 API 設計是綁在 SwiftUI view 生命週期上的
///    (`.translationTask` modifier 才能拿到 `TranslationSession`),沒辦法脫離 view
///    直接建立 session——`TranslationBridge` 這個隱形 view 就是繞過這個限制的做法,
///    透過 `pendingRequest` 觸發、`resolve(with:)` 完成後把結果丟回呼叫端。
/// 2. 這個 framework 在 LiveContainer 側載(未簽署/ad-hoc)環境下能不能正常運作沒有前例可查。
@MainActor
final class AppleTranslationEngine: ObservableObject, TranslationEngine {

    struct PendingRequest {
        let texts: [String]
        let source: String
        let target: String
        let continuation: CheckedContinuation<[String], Error>
    }

    @Published var pendingRequest: PendingRequest?

    /// 診斷用:定位卡點在 SwiftUI 層(.translationTask 沒觸發)還是系統 API 本身。
    @Published private(set) var debugLog: [String] = []

    private func log(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        debugLog.append("[\(stamp)] \(line)")
    }

    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] {
        log("translate() 被呼叫,\(texts.count) 段文字,\(source)→\(target)")
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingRequest = PendingRequest(texts: texts, source: source, target: target, continuation: continuation)
            log("pendingRequest 已設定,等待 .translationTask 觸發…")
        }
    }

    func resolve(with session: TranslationSession) async {
        log("resolve(with:) 被呼叫 — .translationTask 確定有觸發")
        guard let request = pendingRequest else {
            log("resolve(with:) 被呼叫,但 pendingRequest 是 nil(不應該發生)")
            return
        }
        pendingRequest = nil
        do {
            let requests = request.texts.enumerated().map { index, text in
                TranslationSession.Request(sourceText: text, clientIdentifier: "\(index)")
            }
            log("呼叫 session.translations(from:) 前")
            let responses = try await session.translations(from: requests)
            log("session.translations(from:) 回應成功,\(responses.count) 筆")
            // 官方文件說回傳順序會跟輸入一致,這裡用 clientIdentifier 再保險排序一次
            let ordered = responses.sorted {
                (Int($0.clientIdentifier ?? "0") ?? 0) < (Int($1.clientIdentifier ?? "0") ?? 0)
            }
            request.continuation.resume(returning: ordered.map { $0.targetText })
        } catch {
            log("session.translations(from:) 拋錯:\(error.localizedDescription)")
            request.continuation.resume(throwing: error)
        }
    }
}

/// 掛在畫面上的隱形 view,負責承接 `.translationTask`,實際觸發翻譯 session。
struct TranslationBridge: View {
    @ObservedObject var engine: AppleTranslationEngine

    private var configuration: TranslationSession.Configuration? {
        guard let request = engine.pendingRequest else { return nil }
        return TranslationSession.Configuration(
            source: Locale.Language(identifier: request.source),
            target: Locale.Language(identifier: request.target)
        )
    }

    var body: some View {
        Color.clear
            .translationTask(configuration) { session in
                await engine.resolve(with: session)
            }
    }
}

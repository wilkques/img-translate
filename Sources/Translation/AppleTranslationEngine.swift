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

    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            self.pendingRequest = PendingRequest(texts: texts, source: source, target: target, continuation: continuation)
        }
    }

    func resolve(with session: TranslationSession) async {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        do {
            let requests = request.texts.enumerated().map { index, text in
                TranslationSession.Request(sourceText: text, clientIdentifier: "\(index)")
            }
            let responses = try await session.translations(from: requests)
            // 官方文件說回傳順序會跟輸入一致,這裡用 clientIdentifier 再保險排序一次
            let ordered = responses.sorted {
                (Int($0.clientIdentifier ?? "0") ?? 0) < (Int($1.clientIdentifier ?? "0") ?? 0)
            }
            request.continuation.resume(returning: ordered.map { $0.targetText })
        } catch {
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

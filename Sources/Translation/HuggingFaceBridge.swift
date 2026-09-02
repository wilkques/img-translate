import Foundation
import HuggingFace
import MLXLMCommon
import Tokenizers

// MARK: - Downloader

enum HubDownloadError: LocalizedError {
    case invalidRepositoryID(String)
    /// ⚠️ 2026-09-02 新增:選單裡放了一個「猜的」repo id
    /// (`LiquidAI/LFM2.5-VL-3B-MLX-4bit`,事後查證根本不存在),裝機選下去
    /// **直接閃退**——崩潰記錄是 `EXC_BREAKPOINT`/`SIGTRAP`
    /// (`_assertionFailure`),Swift 執行期 trap 沒辦法用 `try/catch` 接住,
    /// 一觸發整個 process 就死。為了讓「repo 不存在」變成看得到的錯誤訊息
    /// 而不是閃退,`LocalModelStore.verifyRepositoryExists` 會在下載前先問一次
    /// Hugging Face API,404 就丟這個錯。
    case repositoryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            return "Hugging Face repo id 格式錯誤:'\(id)'(應為 namespace/name)"
        case .repositoryNotFound(let id):
            return "Hugging Face 上找不到這個模型:'\(id)'——repo id 打錯或該量化版本不存在"
        }
    }
}

/// 把 `HuggingFace.HubClient` 包成 mlx-swift-lm 的 `Downloader`。
/// 刻意手寫這層轉接(不用官方 MLXHuggingFace macro),避免拉進
/// swift-syntax macro plugin 跟 vendored xgrammar C++,拖慢編譯時間。
struct HubSnapshotDownloader: MLXLMCommon.Downloader {
    private let upstream: HubClient

    init(_ upstream: HubClient) {
        self.upstream = upstream
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw HubDownloadError.invalidRepositoryID(id)
        }
        return try await upstream.downloadSnapshot(
            of: repoID,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
    }
}

// MARK: - Tokenizer

/// 把 swift-transformers 的 `Tokenizers.Tokenizer` 轉接成 `MLXLMCommon.Tokenizer`。
/// 兩個模組都有叫 `Tokenizer` 的型別,一律寫全名避免混淆。
struct HuggingFaceTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers 用 decode(tokens:),mlx-swift-lm 要 decode(tokenIds:)
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

struct HuggingFaceTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return HuggingFaceTokenizerBridge(upstream)
    }
}

import SwiftUI

/// 第一輪風險驗證畫面:輸入漫畫網址、捲動頁面,下方除錯清單顯示 JS 偵測到的
/// 每張圖片網址跟原生端下載結果(成功/失敗+原因)。**這輪刻意不接翻譯**——
/// 要先確認「抓得到圖」這個前提成立,再投入下一輪的完整 pipeline 整合(見
/// vault 規劃文件)。
struct MangaReaderView: View {
    @StateObject private var coordinator = TranslationRequestCoordinator()
    @State private var urlField = ""
    @State private var loadedURL: URL?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("貼上漫畫網址", text: $urlField)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .onSubmit(loadURL)
                Button("前往", action: loadURL)
                    .buttonStyle(.borderedProminent)
            }

            Text(coordinator.pageStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            MangaWebView(urlToLoad: loadedURL, coordinator: coordinator)
                .frame(maxHeight: .infinity)

            Text("偵測到的圖片(\(coordinator.probes.count))")
                .font(.caption).bold()
                .frame(maxWidth: .infinity, alignment: .leading)

            probeDebugList
        }
        .padding()
    }

    private func loadURL() {
        guard let url = normalizedURL(from: urlField) else { return }
        loadedURL = url
    }

    private func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://\(trimmed)")
    }

    private var probeDebugList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(coordinator.probes) { probe in
                    Text(Self.line(for: probe))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Self.color(for: probe.status))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 200)
    }

    private static func line(for probe: TranslationRequestCoordinator.ImageProbe) -> String {
        let shortURL = probe.url.lastPathComponent.isEmpty
            ? probe.url.absoluteString
            : probe.url.lastPathComponent
        switch probe.status {
        case .detected:
            return "🔍 偵測到:\(shortURL)"
        case .downloading:
            return "⬇️ 下載中:\(shortURL)"
        case .success(let bytes, let size):
            return "✅ \(shortURL) — \(bytes) bytes,\(Int(size.width))×\(Int(size.height))"
        case .failed(let message):
            return "❌ \(shortURL) — \(message)"
        }
    }

    private static func color(for status: TranslationRequestCoordinator.ImageProbe.Status) -> Color {
        switch status {
        case .detected, .downloading: return .secondary
        case .success: return .green
        case .failed: return .red
        }
    }
}

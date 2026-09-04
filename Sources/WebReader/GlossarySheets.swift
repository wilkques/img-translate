import SwiftUI

/// 釘選一筆人名詞庫條目。原文永遠唯讀——手打會破壞
/// `GlossaryStore.normalize` 要求的精確比對,而這正是從除錯清單的
/// 「VLM讀到」欄位開始釘選(而不是另開一個要手動打原文的畫面)的理由。
/// 譯文用模型當下的輸出當初始值,常見情況只是一兩個字翻錯,兩下就改完。
struct GlossaryPinSheet: View {
    let original: String
    @State var translated: String
    @ObservedObject var glossary: GlossaryStore
    @Environment(\.dismiss) private var dismiss

    private var trimmedTranslated: String {
        translated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("原文(不可編輯)") {
                    Text(original)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                Section("譯文") {
                    TextField("輸入正確譯名", text: $translated)
                }
            }
            .navigationTitle("釘選譯名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        glossary.upsert(original: original, translated: trimmedTranslated)
                        dismiss()
                    }
                    .disabled(trimmedTranslated.isEmpty)
                }
            }
        }
    }
}

/// 詞庫清單/刪除入口。錯誤訊息(檔案讀寫失敗)只在這裡出現——絕不阻擋或
/// 打斷翻譯流程本身,見 `GlossaryStore.lastError` 的說明。
struct GlossaryListSheet: View {
    @ObservedObject var glossary: GlossaryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let error = glossary.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if glossary.entries.isEmpty {
                    Text("還沒有釘選任何譯名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(glossary.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.original)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.translated)
                    }
                }
                .onDelete { offsets in
                    glossary.remove(atOffsets: offsets)
                }
            }
            .navigationTitle("人名詞庫")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        }
    }
}

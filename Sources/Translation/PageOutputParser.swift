import Foundation

/// 整頁輸出的解析與對位工具。
///
/// **刻意做成獨立的 free-standing `enum`,不掛在 `VLMTranslationEngine` 上**:
/// 那個 class 是 `@MainActor`,先前兩次編譯失敗都踩在「`nonisolated` 情境呼叫
/// MainActor-isolated static」這個坑上。獨立型別沒有 isolation 可以繼承,
/// 從任何地方呼叫都不會有問題,結構上不可能再犯同一個錯。
///
/// 也**刻意不做串流增量解析**:整段輸出收完再一次解析就好,`maxTokens` 本身就是
/// 上界。少一整層狀態機 = 少一類在沒有本機編譯器的情況下抓不到的錯。
enum PageOutputParser {

    // MARK: - 解析

    /// 期望格式(`BLOCK` 行可有可無,模型漏掉也要解析得出來):
    ///
    ///     BLOCK 1
    ///     ORIGINAL: ...
    ///     TRANSLATION: ...
    ///     BLOCK 2
    ///     ...
    ///
    /// 寬鬆解析,不做嚴格驗證——4B 模型偶爾不照格式是常態,不能因此讓整頁報廢。
    /// 認不得的行(模型多講的畫面描述之類)一律忽略。
    static func parse(_ raw: String, maxItems: Int) -> [PageTextItem] {
        var items: [PageTextItem] = []
        var pending: PageTextItem?
        var pendingLines: [String] = []

        func flush() {
            guard var item = pending else { return }
            item.rawSlice = pendingLines.joined(separator: "\n")
            let translated = item.translated.trimmingCharacters(in: .whitespaces)
            item.isDegenerate = translated.isEmpty || isDegenerateLine(translated)
            item.order = items.count
            items.append(item)
            pending = nil
            pendingLines = []
        }

        func newPending() -> PageTextItem {
            PageTextItem(index: items.count + 1, order: items.count, original: "", translated: "")
        }

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            if items.count >= maxItems { break }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.range(of: "BLOCK", options: [.caseInsensitive, .anchored]) != nil {
                flush()
                var item = newPending()
                if let n = leadingNumber(in: line) { item.index = n }
                pending = item
                pendingLines = [line]
                continue
            }

            if let r = line.range(of: "ORIGINAL", options: [.caseInsensitive, .anchored]) {
                // 模型漏掉 BLOCK 行時,遇到第二個 ORIGINAL 就隱含換一個新項目。
                if pending == nil || pending?.original.isEmpty == false {
                    flush()
                    pending = newPending()
                }
                pending?.original = value(after: r, in: line)
                pendingLines.append(line)
                continue
            }

            if let r = line.range(of: "TRANSLATION", options: [.caseInsensitive, .anchored]) {
                if pending == nil { pending = newPending() }
                pending?.translated = value(after: r, in: line)
                pendingLines.append(line)
                continue
            }
        }
        flush()
        return items
    }

    /// 抓關鍵字後面的值。`ORIGINAL: x` / `ORIGINAL 2: x` / `ORIGINAL2: x` 都要吃得下
    /// ——模型常常自己在關鍵字後面補編號。
    private static func value(after keywordRange: Range<String.Index>, in line: String) -> String {
        var rest = String(line[keywordRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        while let first = rest.first, first.isNumber { rest.removeFirst() }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix(":") { rest.removeFirst() }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// 取出行內第一個數字(給 `BLOCK 2` 這種行用)。
    private static func leadingNumber(in line: String) -> Int? {
        let digits = line.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// 同一個非空白字元在**同一行內**連續出現超過門檻 → 判定這行卡進重複迴圈。
    ///
    /// ⚠️ 一定要逐行判,不可以拿整段輸出去判:整頁輸出裡出現「啊啊啊啊…」這種
    /// 正常的中文疊字狀聲詞譯文很合理,用整段門檻 12 會把好的整頁結果誤殺掉。
    static func isDegenerateLine(_ line: String, threshold: Int = 12) -> Bool {
        var runLength = 0
        var previous: Character?
        for ch in line where !ch.isWhitespace {
            if ch == previous {
                runLength += 1
                if runLength >= threshold { return true }
            } else {
                runLength = 1
            }
            previous = ch
        }
        return false
    }

    // MARK: - 對位

    /// 對位用的正規化:小寫、去音標、只留英數字元,**最後把連續重複字元收成一個**。
    ///
    /// 最後那步是關鍵:prompt 要求模型只寫 2-4 次重複,Vision 讀到的卻是原圖實際的
    /// 重複次數,不收斂的話 `UWAAA` 跟 `LWAA` 這種永遠配不上。收斂後
    /// `¡UWA! ¡¡UWAA!!` → `uwauwa`、`¡LIWA! ¡¡LWAA!!` → `liwalwa`,相似度就夠高了。
    static func fold(_ s: String) -> String {
        let normalized = s.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        var previous: Character?
        for ch in normalized where ch.isLetter || ch.isNumber {
            if ch == previous { continue }
            out.append(ch)
            previous = ch
        }
        return out
    }

    /// 字元 bigram 的 Dice 係數(0-1)。
    ///
    /// 刻意不用 Levenshtein:Dice 只要十來行、沒有二維陣列索引,在沒有本機編譯器
    /// 的情況下盲寫不容易錯;而對位只需要判斷「像不像」,不需要精確的編輯距離。
    static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }

        let aGrams = bigrams(a)
        let bGrams = bigrams(b)
        guard !aGrams.isEmpty, !bGrams.isEmpty else { return 0 }

        var counts: [String: Int] = [:]
        for gram in aGrams { counts[gram, default: 0] += 1 }

        var overlap = 0
        for gram in bGrams {
            if let remaining = counts[gram], remaining > 0 {
                counts[gram] = remaining - 1
                overlap += 1
            }
        }
        return 2.0 * Double(overlap) / Double(aGrams.count + bGrams.count)
    }

    private static func bigrams(_ s: String) -> [String] {
        let chars = Array(s)
        guard chars.count >= 2 else { return [] }
        return (0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) }
    }
}

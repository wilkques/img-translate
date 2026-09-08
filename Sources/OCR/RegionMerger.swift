import Foundation
import CoreGraphics

/// 合併後的「一顆對話框」。座標統一用圖片像素、原點左上——裁圖(`CGImage.cropping`)
/// 跟疊字(`CoordinateTransform.viewRect(forImagePixelRect:)`)都吃這個格式,
/// 全流程統一一種座標,少一類 bug。
struct TextRegion: Identifiable {
    let id = UUID()
    let pixelRect: CGRect
    /// 合併前 Vision 各行的辨識文字(由上到下排序),只做除錯與 fallback 顯示用,
    /// 不送去翻譯——實際送去 VLM 的是裁圖本身,不是這段文字。
    let visionTexts: [String]
    var visionText: String { visionTexts.joined(separator: " ") }
    /// 2026-09-04:合併前每一行的第 2、3 名候選字串,攤平成一個陣列(不保留
    /// 是哪一行的,純文字模式只是把這些當「其他可能讀法」的提示塞進 prompt,
    /// 不需要精確對應到哪個字)。
    let visionAlternates: [String]
    /// 2026-09-04:VisionKit `ImageAnalyzer`(Safari 同款引擎)讀到的文字,
    /// 在 `RegionMerger.merge` 跑完之後才由呼叫端用相似度配對填入,預設
    /// `nil`(配對不到或這個功能不可用時的正常狀態)。
    var liveText: String?
    /// 實際要送去翻譯的文字:優先用 `ImageAnalyzer` 的(品質較高),配對不到
    /// 才退回 Vision 原始辨識結果。`visionText` 本身維持不變,除錯清單需要
    /// 同時看到兩者才驗證得出這個修法有沒有生效。
    var bestText: String { liveText ?? visionText }

    /// 2026-09-08:供純文字翻譯 prompt 的 `ocrAlternates` 欄位使用——這一塊
    /// 文字的「其他可能讀法」,讓模型自己判斷哪個讀法組得出通順的句子。
    ///
    /// 起因:`bestText` 優先採用 `liveText`(`ImageAnalyzer`),但裝機抓到
    /// `ImageAnalyzer` 在裁圖後偶爾讀得比 Vision 本身還離譜(案例:Vision
    /// 讀「ARE ANTES」,裁圖後 `ImageAnalyzer` 讀成「NEE ANTES」)。原本
    /// 想在兩者之間「二選一」(相似度不夠就退回 Vision),但字元相似度
    /// 對「開頭一個字讀錯、其餘共用」這種錯誤天生不敏感(`ARE ANTES` 跟
    /// `NEE ANTES` 共用整個 `ANTES` 字尾,折疊後相似度依然很高,擋不掉;
    /// 提高門檻又會連 `MLGYEOM`→`MUGYEOM` 這種真正該採用的單字母校正
    /// 一起擋掉,兩者落在同一個相似度區間)——這條路線已經証實走不通。
    ///
    /// 改成不挑,兩個讀法都給模型:`bestText` 照舊當主要文字(平均而言
    /// `ImageAnalyzer` 還是比較準,`MUGYEOM` 案例是已驗證的成功案例),
    /// 但把 `visionText`(另一顆引擎的獨立讀法,資訊量比 Vision 自己的
    /// 第 2、3 名候選高很多)併進 `ocrAlternates` 清單,讓模型自己判斷。
    /// `liveText == nil` 時 `bestText == visionText`,`visionText` 會被
    /// 下面的去重擋掉,行為跟改動前逐字元相同,不影響絕大多數案例。
    ///
    /// 上限 3 筆——`notes/2026-09-01.md` 已經證實 prompt 總指令量是這顆
    /// 模型的失敗驅動因素之一。順帶注意:合併過的多行區塊(`merge` 把
    /// 每行的候選 `a.alternates + b.alternates` 攤平相加)原本可能累積到
    /// 5、6 筆候選,這個上限同時也讓合併區塊的候選數量變少,不是只在
    /// 這次新增的來源上加量。
    func alternateReadings(max: Int = 3) -> [String] {
        var seen = Set([PageOutputParser.fold(bestText)])
        var result: [String] = []
        for candidate in [visionText] + visionAlternates {
            guard result.count < max else { break }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = PageOutputParser.fold(trimmed)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }
}

enum RegionMerger {
    /// 合併「撐大後會碰撞」的相鄰文字框,一顆對話框常被 Vision 拆成好幾行各自的
    /// bbox,分開裁圖會讓 VLM 看不到完整語句上下文、也會讓疊字互相重疊
    /// (裝機實測過,見 README)。撐大倍率沿用畫面疊字驗證過的寬 1.5/高 1.0。
    static func merge(
        _ blocks: [RecognizedTextBlock],
        pixelWidth: Int,
        pixelHeight: Int,
        widthInflate: CGFloat = 1.5,
        heightInflate: CGFloat = 1.0
    ) -> [TextRegion] {
        guard pixelWidth > 0, pixelHeight > 0 else { return [] }

        struct Item {
            var texts: [String]
            var alternates: [String]
            var rect: CGRect   // 原始(未撐大)像素座標
        }

        func inflated(_ r: CGRect) -> CGRect {
            let w = r.width * widthInflate
            let h = r.height * heightInflate
            return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
        }

        var items: [Item] = blocks.compactMap { block in
            guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let rect = CoordinateTransform.imagePixelRect(
                forNormalizedVisionBox: block.normalizedBoundingBox,
                imagePixelSize: CGSize(width: pixelWidth, height: pixelHeight))
            return Item(texts: [block.text], alternates: block.alternates, rect: rect)
        }

        // 重複掃描、合併任何一對撐大後會碰撞的框,直到沒有東西可合併為止。
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for i in items.indices {
                for j in items.indices where j > i {
                    guard inflated(items[i].rect).intersects(inflated(items[j].rect)) else { continue }
                    let a = items[i], b = items[j]
                    // 由上到下排序:pixel 座標 y 越小代表畫面越上面。
                    let mergedTexts = a.rect.minY <= b.rect.minY
                        ? a.texts + b.texts
                        : b.texts + a.texts
                    items[i] = Item(
                        texts: mergedTexts, alternates: a.alternates + b.alternates,
                        rect: a.rect.union(b.rect))
                    items.remove(at: j)
                    didMerge = true
                    break outer
                }
            }
        }

        // 合併迴圈的 `items.remove(at: j)` 會讓陣列順序變成任意,這裡補上閱讀順序排序。
        // 這是整頁路線「依順序對位」的硬前提(模型依閱讀順序列出文字,我們的區塊也
        // 必須是同一個順序),順帶讓除錯清單變成由上到下排列,裝機截圖好判讀很多。
        // 疊字渲染與陣列索引無關,重排不影響畫面。
        return items
            .sorted { readingOrderPrecedes($0.rect, $1.rect) }
            .map { TextRegion(pixelRect: $0.rect, visionTexts: $0.texts, visionAlternates: $0.alternates) }
    }

    /// 閱讀順序:由上到下;垂直範圍重疊超過較矮那塊的一半時視為同一列,改由左到右。
    static func readingOrderPrecedes(_ a: CGRect, _ b: CGRect) -> Bool {
        let verticalOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        if verticalOverlap > min(a.height, b.height) * 0.5 {
            return a.minX < b.minX
        }
        return a.minY < b.minY
    }
}

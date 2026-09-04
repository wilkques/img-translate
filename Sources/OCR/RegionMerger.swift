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

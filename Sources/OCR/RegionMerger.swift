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
            return Item(texts: [block.text], rect: rect)
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
                    items[i] = Item(texts: mergedTexts, rect: a.rect.union(b.rect))
                    items.remove(at: j)
                    didMerge = true
                    break outer
                }
            }
        }

        return items.map { TextRegion(pixelRect: $0.rect, visionTexts: $0.texts) }
    }
}

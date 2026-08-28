import CoreGraphics
import UIKit

enum RegionCropper {

    /// Vision 的 normalized box(0-1、原點左下)→ CGImage 像素矩形(原點左上),
    /// 並依比例往外擴邊。
    ///
    /// 座標系統要注意的地方:
    /// 1. 一定要用 `cgImage.width/height`(原始像素),不要用 `UIImage.size`
    ///    (那是「點」,而且已套用 `imageOrientation`)——`CGImage.cropping(to:)`
    ///    吃的是像素。
    /// 2. y 軸要翻:Vision 的 y 由下往上,CGImage 由上往下。
    /// 3. `TextRecognizer` 用 `VNImageRequestHandler(cgImage:options:)`(沒帶
    ///    orientation),所以 Vision 回傳的 box 本來就跟 cgImage 原始像素空間一致,
    ///    不需要額外補償——前提是餵進去的圖已經是 `.up` 方向(見 `normalizedUp`)。
    ///
    /// 擴邊(padding)是必要的,不是美化:Vision 的 bbox 只框住墨跡本身,漫畫手寫
    /// 粗體字常常有超出框的筆畫尾巴、描邊、驚嘆號的點。裁太緊等於把「Vision 認錯」
    /// 換成「VLM 看不到」,沒有解決問題。縱向擴得比橫向多,但不能擴太多——同一個
    /// 對話框裡上下兩行字間距本來就很近,這也是為什麼一定要先用 `RegionMerger`
    /// 合併同一對話框的多行文字,再裁圖:合併後縱向擴邊只會吃到對話框內的留白。
    static func paddedPixelRect(
        forVisionBox box: CGRect,
        pixelWidth: Int,
        pixelHeight: Int,
        padFractionX: CGFloat = 0.08,
        padFractionY: CGFloat = 0.20,
        minPadPixels: CGFloat = 6
    ) -> CGRect {
        let w = CGFloat(pixelWidth)
        let h = CGFloat(pixelHeight)

        let rect = CGRect(
            x: box.minX * w,
            y: (1 - box.maxY) * h,
            width: box.width * w,
            height: box.height * h
        )
        return padded(
            rect, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            padFractionX: padFractionX, padFractionY: padFractionY, minPadPixels: minPadPixels)
    }

    /// 對已經是像素座標的矩形做擴邊 + 夾邊界(合併過的框走這條)
    static func padded(
        _ rect: CGRect,
        pixelWidth: Int,
        pixelHeight: Int,
        padFractionX: CGFloat = 0.08,
        padFractionY: CGFloat = 0.20,
        minPadPixels: CGFloat = 6
    ) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        let dx = max(rect.width * padFractionX, minPadPixels)
        let dy = max(rect.height * padFractionY, minPadPixels)
        return rect.insetBy(dx: -dx, dy: -dy)
            .integral
            .intersection(bounds)
    }

    /// 從 UIImage 裁一小塊出來,回傳 CGImage(像素空間),直接餵給 `CIImage(cgImage:)`。
    /// `CGImage.cropping(to:)` 吃像素、原點左上,rect 完全落在圖外時回傳 nil。
    static func crop(_ image: UIImage, toPixelRect rect: CGRect) -> CGImage? {
        guard let cg = image.cgImage else { return nil }
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return cg.cropping(to: rect)
    }

    /// 把任何 `imageOrientation` 的 UIImage 重畫成 `.up`,讓 Vision 與裁圖保證同座標系。
    /// 已經是 `.up` 就原樣回傳,不做無謂重繪。
    static func normalizedUp(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

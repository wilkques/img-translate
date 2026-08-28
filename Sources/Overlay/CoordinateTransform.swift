import CoreGraphics

enum CoordinateTransform {
    /// Vision 的 boundingBox 是正規化座標(0-1),原點在左下角、height 往上長。
    /// 轉成圖片像素座標(原點左上角)——這個中間格式拿來做「相鄰文字框要不要合併」
    /// 的重疊判斷,跟 view 的實際顯示尺寸無關,穩定不受畫面大小影響。
    static func imagePixelRect(forNormalizedVisionBox box: CGRect, imagePixelSize: CGSize) -> CGRect {
        let pixelX = box.minX * imagePixelSize.width
        let pixelWidth = box.width * imagePixelSize.width
        let pixelHeight = box.height * imagePixelSize.height
        // Vision 的 y 是「從底部算起」,轉成「從頂部算起」:1 - (minY + height)
        let pixelYFromTop = (1 - (box.minY + box.height)) * imagePixelSize.height
        return CGRect(x: pixelX, y: pixelYFromTop, width: pixelWidth, height: pixelHeight)
    }

    /// 圖片像素座標(原點左上角)轉成 SwiftUI 用 `.scaledToFit()` 顯示圖片時,
    /// 畫面上對應的實際矩形(原點左上角,單位是 container 的 point)。
    ///
    /// 純函式,不依賴任何 View 狀態,方便單獨驗證邏輯。
    static func viewRect(
        forImagePixelRect pixelRect: CGRect,
        imagePixelSize: CGSize,
        containerSize: CGSize
    ) -> CGRect {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }

        // aspectFit 的縮放比例與置中留白
        let scale = min(containerSize.width / imagePixelSize.width,
                         containerSize.height / imagePixelSize.height)
        let displayedWidth = imagePixelSize.width * scale
        let displayedHeight = imagePixelSize.height * scale
        let offsetX = (containerSize.width - displayedWidth) / 2
        let offsetY = (containerSize.height - displayedHeight) / 2

        return CGRect(
            x: offsetX + pixelRect.minX * scale,
            y: offsetY + pixelRect.minY * scale,
            width: pixelRect.width * scale,
            height: pixelRect.height * scale
        )
    }

    /// 舊呼叫端相容用:Vision 正規化座標直接轉 view 座標,一次做完兩段轉換。
    static func viewRect(
        forNormalizedVisionBox box: CGRect,
        imagePixelSize: CGSize,
        containerSize: CGSize
    ) -> CGRect {
        let pixelRect = imagePixelRect(forNormalizedVisionBox: box, imagePixelSize: imagePixelSize)
        return viewRect(forImagePixelRect: pixelRect, imagePixelSize: imagePixelSize, containerSize: containerSize)
    }
}

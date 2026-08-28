import CoreGraphics

enum CoordinateTransform {
    /// Vision 的 boundingBox 是正規化座標(0-1),原點在左下角、height 往上長。
    /// 這個函式把它轉成 SwiftUI 用 `.scaledToFit()` 顯示圖片時,畫面上對應的實際矩形
    /// (原點左上角,單位是 container 的 point)。
    ///
    /// 純函式,不依賴任何 View 狀態,方便單獨驗證邏輯。
    static func viewRect(
        forNormalizedVisionBox box: CGRect,
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

        // Vision box → 圖片像素座標(原點左上角)
        let pixelX = box.minX * imagePixelSize.width
        let pixelWidth = box.width * imagePixelSize.width
        let pixelHeight = box.height * imagePixelSize.height
        // Vision 的 y 是「從底部算起」,轉成「從頂部算起」:1 - (minY + height)
        let pixelYFromTop = (1 - (box.minY + box.height)) * imagePixelSize.height

        return CGRect(
            x: offsetX + pixelX * scale,
            y: offsetY + pixelYFromTop * scale,
            width: pixelWidth * scale,
            height: pixelHeight * scale
        )
    }
}

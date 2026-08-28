import CoreGraphics

struct TextBlock: Identifiable {
    let id = UUID()
    let originalText: String
    var translatedText: String?
    /// Vision 原生的 boundingBox:正規化座標(0-1),原點在左下角
    let normalizedBoundingBox: CGRect
}

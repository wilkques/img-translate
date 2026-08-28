import Foundation
import CoreGraphics

struct TextBlock: Identifiable {
    let id = UUID()
    /// Vision 辨識出的原文(合併過同一對話框的多行),只做除錯對照與 fallback 用。
    let visionText: String
    /// VLM 直接讀裁圖辨識出的原文,跟 `visionText` 分開存,方便除錯清單對照兩者差異。
    var recognizedText: String?
    var translatedText: String?
    /// 圖片像素座標,原點左上——裁圖跟疊字統一用這個座標系。
    let pixelRect: CGRect
}

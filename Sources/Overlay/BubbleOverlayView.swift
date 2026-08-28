import SwiftUI
import CoreGraphics

/// 畫一塊遮色矩形蓋住原文,再把翻譯文字置中畫上去。
/// 翻譯後文字長度跟原文不一定一樣長,用 `minimumScaleFactor` 自動縮字避免溢出。
struct BubbleOverlayView: View {
    let text: String
    let rect: CGRect
    var maskColor: Color = .white.opacity(0.96)
    var textColor: Color = .black

    /// Vision 抓的原文 bbox 通常只框住文字墨跡本身(比整顆手繪對話框小很多),
    /// 照原尺寸畫遮色框會讓字擠成一團、被 minimumScaleFactor 壓到很小。
    /// 往外撐一點空間給譯文喘息,中心點不變。
    private static let inflateFactor: CGFloat = 1.35

    private var inflatedSize: CGSize {
        CGSize(width: max(rect.width, 1) * Self.inflateFactor,
               height: max(rect.height, 1) * Self.inflateFactor)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(maskColor)
            Text(text)
                .font(.system(size: startingFontSize, weight: .heavy, design: .default))
                .foregroundColor(textColor)
                .minimumScaleFactor(0.5)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .padding(4)
        }
        .frame(width: inflatedSize.width, height: inflatedSize.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }

    /// 依撐大後的框高抓一個起始字級,實際顯示會被 minimumScaleFactor 再往下縮到不溢出
    private var startingFontSize: CGFloat {
        max(12, inflatedSize.height * 0.6)
    }
}

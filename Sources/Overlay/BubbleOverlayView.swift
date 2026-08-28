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
    /// 照原尺寸畫遮色框會讓字擠成一團、被 minimumScaleFactor 壓到很小,所以往外
    /// 撐一點空間給譯文喘息,中心點不變。寬高撐大的比例不對稱:同一個對話框裡
    /// 常常有相鄰兩行字被 Vision 拆成兩塊各自的 bbox,高度撐太多會讓上下兩塊
    /// 疊在一起(裝機實測過),所以高度只小幅撐大、寬度撐比較多。
    private static let widthInflateFactor: CGFloat = 1.5
    private static let heightInflateFactor: CGFloat = 1.1

    private var inflatedSize: CGSize {
        CGSize(width: max(rect.width, 1) * Self.widthInflateFactor,
               height: max(rect.height, 1) * Self.heightInflateFactor)
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

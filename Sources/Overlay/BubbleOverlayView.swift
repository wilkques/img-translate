import SwiftUI

/// 畫一塊遮色矩形蓋住原文,再把翻譯文字置中畫上去。
/// 翻譯後文字長度跟原文不一定一樣長,用 `minimumScaleFactor` 自動縮字避免溢出。
struct BubbleOverlayView: View {
    let text: String
    let rect: CGRect
    var maskColor: Color = .white.opacity(0.96)
    var textColor: Color = .black

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(maskColor)
            Text(text)
                .font(.system(size: startingFontSize, weight: .bold, design: .rounded))
                .foregroundColor(textColor)
                .minimumScaleFactor(0.3)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .padding(4)
        }
        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }

    /// 依框高抓一個起始字級,實際顯示會被 minimumScaleFactor 再往下縮到不溢出
    private var startingFontSize: CGFloat {
        max(10, rect.height * 0.45)
    }
}

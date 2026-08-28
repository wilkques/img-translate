import Foundation
import Metal
import MLX

/// LiveContainer 環境下 Metal / MLX 能不能用的最小探針。
/// 不下載任何模型,只驗證 GPU 能不能用——先確認環境,再花力氣下載 2.2GB 模型(Stage 2)。
enum MLXSmokeTest {

    static func run() -> String {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return "❌ MTLCreateSystemDefaultDevice() 回 nil — 這個環境拿不到 Metal device"
        }

        var lines: [String] = []
        lines.append("✅ Metal device: \(device.name)")
        lines.append("   recommendedMaxWorkingSetSize: \(device.recommendedMaxWorkingSetSize / 1_048_576) MB")

        // 這一步會觸發 MLX 載入打包在 app bundle 內的 default.metallib
        // (mlx-swift_Cmlx.bundle)。如果 LiveContainer 的 bundle 路徑處理有問題,
        // 會在這裡爆掉(這正是我們要驗的東西),不是默默失敗。
        let a = MLXArray([1, 2, 3, 4] as [Int32])
        let sum = (a * 2).sum().item(Int32.self)
        lines.append("✅ MLX GPU 運算 OK(期望 20,實得 \(sum))")

        return lines.joined(separator: "\n")
    }
}

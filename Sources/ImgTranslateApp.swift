import SwiftUI

@main
struct ImgTranslateApp: App {
    enum Tab: Hashable { case reader, engineTest }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}

/// ⚠️ 2026-09-02:裝機實測發現 OOM 崩潰(系統低記憶體 jetsam 快照,見
/// notes/2026-09-02.md)——根因是 `TabView` 預設會把兩個分頁的畫面都建出來,
/// 不是只建目前選中的那個。`ContentView` 有 `.task` 會一出現就自動對內建
/// 測試圖跑一次翻譯 pipeline(含自動下載/載入 VLM 模型),即使使用者從沒
/// 手動點進「引擎測試」分頁,這個 `.task` 還是會跟著 `TabView` 初始化被觸發,
/// 悄悄在背景載入**第二份**跟「閱讀」分頁各自獨立的 3GB+ 模型,兩份疊起來
/// 就把記憶體推爆。
///
/// 修法:分頁內容改成「目前選到才建立畫面」,沒選到的分頁完全不進入視圖
/// 樹,`.task` 自然不會被觸發。代價是切出「引擎測試」分頁再切回去,
/// `ContentView` 的 `@StateObject` 引擎會被整個重建(等於要重新載入一次
/// 模型權重,不是重新下載——`LocalModelStore` 的檔案快取還在),這是刻意
/// 接受的取捨,換取不會兩份模型同時常駐記憶體。
private struct RootTabView: View {
    @State private var selection: ImgTranslateApp.Tab = .reader

    var body: some View {
        TabView(selection: $selection) {
            Group {
                if selection == .reader { MangaReaderView() }
            }
            .tabItem { Label("閱讀", systemImage: "book") }
            .tag(ImgTranslateApp.Tab.reader)

            Group {
                if selection == .engineTest { ContentView() }
            }
            .tabItem { Label("引擎測試", systemImage: "wrench.and.screwdriver") }
            .tag(ImgTranslateApp.Tab.engineTest)
        }
    }
}

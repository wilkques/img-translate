import SwiftUI

@main
struct ImgTranslateApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                MangaReaderView()
                    .tabItem { Label("閱讀", systemImage: "book") }
                ContentView()
                    .tabItem { Label("引擎測試", systemImage: "wrench.and.screwdriver") }
            }
        }
    }
}

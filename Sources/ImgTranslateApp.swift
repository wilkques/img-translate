import SwiftUI

@main
struct ImgTranslateApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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

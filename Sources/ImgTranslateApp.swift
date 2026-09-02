import SwiftUI

/// ⚠️ 2026-09-02:先前把「引擎測試」(`ContentView`,固定測試圖那個實驗畫面)
/// 跟「閱讀」(`MangaReaderView`)放進同一個 `TabView`,裝機實測 OOM 崩潰——
/// `TabView` 預設會把兩個分頁的畫面都建出來,`ContentView` 的 `.task` 一初始化
/// 就自動觸發跑翻譯 pipeline(含自動下載/載入 VLM 模型),使用者完全沒點過
/// 那個分頁,也會悄悄在背景載入**第二份**跟「閱讀」分頁獨立的 3GB+ 模型,
/// 兩份疊起來把記憶體推爆(詳見 `notes/2026-09-02.md`)。
///
/// Cyril 要求暫時把「引擎測試」整個隱藏掉,先把「閱讀」這條主線測穩。
/// 這裡改成 App 直接顯示 `MangaReaderView()`,不再組 `TabView`——
/// `ContentView.swift` 本身**沒有刪除**,還留在 `Sources/` 底下會被編譯,
/// 只是現在沒有任何地方建立它的實例,所以它的 `.task` 永遠不會被觸發,
/// 不會再有第二份模型的問題。之後要恢復,把下面這行換回組 `TabView`
/// (可以參考 git 歷史 `6b872dd` 那版寫法)即可,不用重寫。
@main
struct ImgTranslateApp: App {
    var body: some Scene {
        WindowGroup {
            MangaReaderView()
        }
    }
}

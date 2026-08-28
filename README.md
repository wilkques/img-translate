# ImgTranslate POC — OCR + 原地疊字翻譯

## 這支 App 在驗什麼

目標效果:`/var/www/try/1.jpg`(原文)→ `/var/www/try/2.jpg`(翻譯後)——**原地蓋掉原文位置、換上翻譯**,不是加字幕。

這支 App 是驗證這個 rendering pipeline 本身走不走得通,用內建的固定測試圖(`Fixtures/sample-es.jpg`,已裁掉手機狀態列/Safari 網址列,只留漫畫內容)。**不含**即時擷取網頁圖片的部分(WKWebView 整合是下一階段)。

流程:App 開啟 → 自動對內建測試圖跑 Vision OCR(抓文字+座標)→ 把辨識到的文字丟給本機 MLX 模型翻譯(見下方)→ 依座標畫遮色框蓋住原文、疊上譯文。畫面上方有語言選單(來源/目標),選好會自動重跑一次;預設西班牙文 → 繁體中文(配合測試圖)。畫面下方有除錯清單顯示「Vision 實際辨識出的原文」,方便判斷效果不對時是辨識錯還是翻譯錯。按鈕可以切換顯示原圖 / 疊字後的畫面,直接跟 `2.jpg` 比對。

## 語言選擇

目前選單提供:西班牙文、英文、日文、韓文、法文、德文、簡體中文、繁體中文(台灣)。這是固定清單,對應 `LocalLLMTranslationEngine.languageNameMap` 有映射的語言。測試圖本身是西班牙文,選別的來源語言時 Vision 辨識會不準是正常的(圖片內容沒變,只是叫辨識器用別種語言的字型規則去猜)。

## 建 repo 與 push

這份 repo 已經在本機 `git init` + commit 過,預設 branch 是 `master`(跟 `lc-memprobe` 一樣)。

```bash
cd C:\works\projects\img-translate
git remote add origin https://github.com/<你的帳號>/img-translate.git
git push -u origin master
```

## 下載 artifact 與安裝

跟 `lc-memprobe`完全一樣:Actions 分頁 → 最新成功的 run → 最下方 Artifacts → 下載 `ImgTranslate-ipa`(zip,裡面兩個 ipa)→ LiveContainer 匯入 `ImgTranslate-unsigned.ipa`,失敗就換 `ImgTranslate-adhoc.ipa`。

## 驗證步驟

1. 打開 App,等它自動跑完 OCR + 翻譯(畫面上的「狀態」文字會顯示進度)
2. **先看畫面下方的除錯清單**——每一行是「原文 → 譯文」,檢查 Vision 有沒有把 `¡¡¡GRRRRRRAAAAGH!!!!` 這種狀聲詞、`YA BASTA...` 這種手寫感粗體字正確辨識出來
3. 看主畫面的疊字效果,跟 `/var/www/try/2.jpg` 目視比對——遮色框位置對不對、翻譯文字有沒有溢出框外
4. 按底部按鈕切換「顯示原圖」,確認原圖本身正常顯示(排除是圖片本身載入失敗的問題)
5. 把畫面截圖、除錯清單內容貼回來給 Jarvis

## 已知風險與待驗證項目

- Apple 系統 Translation framework 在 LiveContainer 下**已確認不行**(`session.translations(from:)` 送出去後永遠卡住,不拋錯也不完成),已從程式碼裡整個移除,現在唯一的翻譯引擎是本機 MLX 模型
- **Vision 對漫畫手寫感粗體字/狀聲詞的辨識準確度未知**——除錯清單就是為了讓這個問題看得見
- **翻譯文字比原文長/短時的排版效果**需要肉眼確認,不是靠邏輯能保證好看

## 下一步(這次不做)

WKWebView 即時擷取網頁圖片(取代這次寫死的固定測試圖)、自動換頁偵測。

## MLX 本機模型探針(Stage 0/1)✅ 已通過

裝機實測結果:`✅ Metal device: Apple A19 Pro GPU`、`✅ MLX GPU 運算 OK(期望 20,實得 20)`——LiveContainer 側載環境下 Metal GPU 運算完全正常,不需要簽署或特殊 entitlement。這是原計畫最大的未知風險,現在確認排除。

同時也確認了 Apple 系統 Translation framework 在這個環境下會永遠卡住(見上方已知風險),已從程式碼移除。本機模型翻譯不是「可選的加分項」,是**達到「App 內即時翻譯、不跳轉」這個需求唯一還活著的路線**。

## MLX 本機模型翻譯(Stage 2)

真正接上模型:`mlx-community/translategemma-4b-it-4bit_immersive-translate`(TranslateGemma 4B 翻譯專用微調,重新包過 chat template 給一般推理引擎用)。這是唯一的翻譯引擎,不再有系統翻譯選項。

⚠️ **中途踩過一個坑**:TranslateGemma 官方 chat template 要求結構化 content 格式,不吃我們原本用的 `additionalContext` 塞法,實測會直接 `Jinja.TemplateException`。已改用 `_immersive-translate` 這個變體版本,語言資訊改用純文字分隔符號包在 prompt 裡送(`<<<source>>>English<<<target>>>Chinese (Traditional)<<<text>>>原文`),不再需要結構化 content。

**首次使用流程**:
1. 打開 App
2. **務必連 WiFi**——首次會自動下載約 2.2GB 的模型檔案到 `Application Support`(不是 Caches,不會被系統清掉),下載進度條會顯示在語言選單下方
3. 下載完成後短暫「載入模型權重中…」
4. 之後才開始逐句翻譯,顯示「本機模型翻譯中 N/總數」
5. 全部完成後套用到疊字畫面,跟 `/var/www/try/2.jpg` 比對

**這是完全沒驗過的環節**,重點觀察並回報:
- 下載進度條有沒有正常跑、卡在多少 % 或直接失敗
- 下載完成後載入權重要等多久
- 實際跑一句翻譯要等幾秒(推理速度)
- 過程中 App 有沒有被系統強制關閉(記憶體問題——雖然 `lc-memprobe` 驗過 entitlement 開了約 6GB,但那是純記憶體佔用測試,沒有實際跑 GPU 推理)
- 翻譯出來的中文品質,跟你印象中 Locally AI 的翻譯品質比較

**已知的技術細節**:
- 模型下載到 LiveContainer 的 App 專屬 container,重新裝新版 ipa **不會**清掉已下載的模型(除非在 LiveContainer 對這個 App 執行 Delete Data/Remove Container),之後改程式碼重新 push 不用每次重下 2.2GB
- 語言選單的代碼(如 `zh-Hant-TW`)已經在程式碼裡映射成模板要的完整英文語言名稱(如 "Chinese (Traditional)"),其他語言選項也都有映射,理論上都能用

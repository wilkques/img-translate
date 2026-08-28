# ImgTranslate POC — OCR + 原地疊字翻譯

## 這支 App 在驗什麼

目標效果:`/var/www/try/1.jpg`(原文)→ `/var/www/try/2.jpg`(翻譯後)——**原地蓋掉原文位置、換上翻譯**,不是加字幕。

這支 App 是驗證這個 rendering pipeline 本身走不走得通,用內建的固定測試圖(`Fixtures/sample-es.jpg`,已裁掉手機狀態列/Safari 網址列,只留漫畫內容)。**不含**即時擷取網頁圖片的部分(WKWebView 整合是下一階段)。

流程:App 開啟 → 自動對內建測試圖跑 Vision OCR(抓文字+座標)→ 把辨識到的文字丟給系統 Translation framework 翻譯 → 依座標畫遮色框蓋住原文、疊上譯文。畫面上方有兩個語言選單(來源/目標),選好會自動重跑一次;預設西班牙文 → 繁體中文(配合測試圖)。畫面下方有除錯清單顯示「Vision 實際辨識出的原文」,方便判斷效果不對時是辨識錯還是翻譯錯。按鈕可以切換顯示原圖 / 疊字後的畫面,直接跟 `2.jpg` 比對。

## 語言選擇

目前選單提供:西班牙文、英文、日文、韓文、法文、德文、簡體中文、繁體中文(台灣)。這是固定清單(沒有即時查裝置實際支援哪些語言對),某個語言對如果 Apple Translation 不支援,狀態列會顯示「失敗:...」的錯誤訊息,不會讓 App 卡死或閃退。測試圖本身是西班牙文,選別的來源語言時 Vision 辨識會不準是正常的(圖片內容沒變,只是叫辨識器用別種語言的字型規則去猜)。

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

- **Apple Translation framework 在 LiveContainer 側載(未簽署/ad-hoc)環境下能不能正常運作,沒有前例可查**——如果 App 卡在「翻譯中…」不動,或跳出跟語言包下載相關的系統提示但沒反應,這就是踩到這個地雷,記錄下來回報
- **Vision 對漫畫手寫感粗體字/狀聲詞的辨識準確度未知**——除錯清單就是為了讓這個問題看得見
- **翻譯文字比原文長/短時的排版效果**需要肉眼確認,不是靠邏輯能保證好看
- 語言包如果系統還沒下載過,理論上會跳出下載提示(跟 Safari 翻譯同一套機制),需要有網路連線

## 下一步(這次不做)

WKWebView 即時擷取網頁圖片(取代這次寫死的固定測試圖)、自動換頁偵測。

## MLX 本機模型探針(Stage 0/1)

這次新增 `MLXLLM`/`MLXLMCommon`/`MLX` 三個 SPM 依賴,但**還沒真的接模型**——先驗證 Metal GPU 運算能不能在 LiveContainer 側載環境下正常運作,這是接下來要跑 Gemma/Qwen 本機翻譯模型的前提,而且完全沒有前例可查(社群對另一支 App「Provenance」的說法是 LiveContainer 限制 Metal GPU 存取,但那主要跟 JIT 有關,不確定適不適用於 MLX 這種用預編譯 metallib、不需要 runtime 編 shader 的用法)。

**這次編譯時間會明顯變長**(mlx-swift 的 C++ 核心 + 上百個 Metal shader,估計 20–40 分鐘,workflow timeout 已從 30 分鐘調到 90 分鐘),第一次 push 請有心理準備等久一點,失敗的話看 Actions log 的「解析 SPM 依賴」或「編譯」哪一步出錯。

**測試方式**:App 畫面最下方多一顆「MLX 自我檢測」按鈕,不用等 OCR/翻譯跑完就能按。按下去會顯示三種結果之一:

| 結果 | 意義 | 下一步 |
|---|---|---|
| `❌ MTLCreateSystemDefaultDevice() 回 nil` | LiveContainer 真的擋掉 Metal | 這條路不可行,本機模型翻譯要退回雲端 API 或换正式簽署的 App |
| 拿到 Metal device,但按下去閃退 | metallib 打包或定位問題 | 回報給 Jarvis,查 CI log 的「驗證 MLX metallib 有被打包」那步有沒有過 |
| 顯示 `✅ Metal device: ...` + `✅ MLX GPU 運算 OK(期望 20,實得 20)` | 環境沒問題 | 可以進 Stage 2:真正下載 TranslateGemma 模型接上翻譯 |

把按鈕顯示的完整文字貼回來給 Jarvis 判讀。

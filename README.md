# ImgTranslate POC — OCR + 原地疊字翻譯

## 這支 App 在驗什麼

目標效果:`/var/www/try/1.jpg`(原文)→ `/var/www/try/2.jpg`(翻譯後)——**原地蓋掉原文位置、換上翻譯**,不是加字幕。

這支 App 是驗證這個 rendering pipeline 本身走不走得通,用內建的固定測試圖(`Fixtures/sample-es.jpg`,已裁掉手機狀態列/Safari 網址列,只留漫畫內容)。**不含**即時擷取網頁圖片的部分(WKWebView 整合是下一階段)。

流程:App 開啟 → 自動對內建測試圖跑 Vision OCR(抓文字+座標)→ 把辨識到的文字丟給系統 Translation framework 翻譯(西班牙文 → 繁體中文)→ 依座標畫遮色框蓋住原文、疊上譯文。畫面下方有除錯清單顯示「Vision 實際辨識出的原文」,方便判斷效果不對時是辨識錯還是翻譯錯。右下角按鈕可以切換顯示原圖 / 疊字後的畫面,直接跟 `2.jpg` 比對。

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

驗證通過後才進行:WKWebView 即時擷取網頁圖片(取代這次寫死的固定測試圖)、串接 MLX Swift 本機模型(`Sources/Translation/LocalLLMTranslationEngine.swift` 已留好介面卡槽)、自動換頁偵測。

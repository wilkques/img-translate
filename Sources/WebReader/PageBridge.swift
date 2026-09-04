import Foundation

/// 注入進網頁的偵測+疊字腳本。
///
/// 設計重點:
/// - 用 `IntersectionObserver` + 放大的 `rootMargin`(往下多抓 2 個螢幕高度)
///   提前偵測即將捲入視窗的圖片,而不是等圖片真的可見才回報——這是「看起來
///   即時」的關鍵,原生端才有時間先把翻譯準備好。
/// - 漫畫站幾乎都用 lazy-load(先塞 `data-src`,捲到才由網站自己的 JS 換成
///   `src`),`IntersectionObserver` 進入視窗那一刻不保證 `src` 已經換好,所以
///   額外用 `MutationObserver` 盯每個 `<img>` 的屬性變化,src 換好才真的回報。
/// - 用 `MutationObserver` 盯整個文件的節點新增,涵蓋無限捲動網站動態插入
///   新 `<img>` 的情況(不是只在頁面剛載入時掃一次)。
/// - **只在真的要回報翻譯的圖片上動 DOM 結構**(包一層定位用的 wrapper):
///   如果對頁面上每個 `<img>`(含小圖示、廣告、頭像)都無條件包 wrapper,
///   會不必要地干擾站方自己的版面(尤其 flex/grid 版面依賴 `<img>` 是直接
///   子元素的情況)。只有通過 `isCandidate`(夠大、真的像漫畫格)的圖片才會
///   被包一層,縮小對原站版面的影響範圍。
enum PageBridge {
    static let source = #"""
    (function () {
      if (window.__imgTranslateInstalled) { return; }
      window.__imgTranslateInstalled = true;

      var watched = new WeakSet();
      var counter = 0;

      // ⚠️ 2026-09-03:原本只看 `getBoundingClientRect()`(實際渲染尺寸)。
      // 有些站的 lazy-load 圖片在真正換上 src 之前,版面是用小尺寸/未定型的
      // 佔位元素撐著(不像有明確 CSS aspect-ratio 或 width/height 屬性保留版位
      // 的做法),導致我們的 IntersectionObserver 提早(200% 螢幕高度)偵測到
      // 時,`rect` 還是 0 或很小,`isCandidate` 判定失敗、不回報;等站方自己
      // 換好 src、我們的 `MutationObserver` 才重新檢查一次時,通常已經逼近
      // 站方自己(通常門檻比我們窄很多)判定「該載入了」的時間點,等於我們
      // 提早偵測的設計被這個尺寸門檻抵銷掉了。改成優先看 HTML 上明確宣告的
      // `width`/`height` 屬性(多數保留版位用的站會先寫這個,即使圖還沒載入),
      // 量不到才退回實際渲染尺寸。
      function isCandidate(img) {
        var declaredW = parseInt(img.getAttribute('width'), 10);
        var declaredH = parseInt(img.getAttribute('height'), 10);
        if (declaredW >= 200 && declaredH >= 200) { return true; }
        var rect = img.getBoundingClientRect();
        return rect.width >= 200 && rect.height >= 200;
      }

      // 多蒐集幾個常見的 lazy-load 屬性名稱——不同站/不同 lazy-load 套件用的
      // 屬性名不一樣,`data-src` 只是最常見的一種,漏掉其他命名就會在真正的
      // `src` 換好前完全拿不到任何網址,只能乾等站方自己觸發換好。
      function currentSrc(img) {
        return img.currentSrc || img.src ||
          img.getAttribute('data-src') ||
          img.getAttribute('data-original') ||
          img.getAttribute('data-lazy-src') ||
          img.getAttribute('data-lazy') ||
          '';
      }

      // 只在真的要回報時才包一層 wrapper——避免動到頁面上每一個 <img>
      // (小圖示/廣告/頭像從來不會通過 isCandidate,不需要也不應該被包)。
      function ensureWrapped(img) {
        if (img.__imgTranslateWrapped) { return img.parentElement; }
        var wrapper = document.createElement('div');
        wrapper.setAttribute('data-imgtranslate-wrapper', img.__imgTranslateId);
        wrapper.style.position = 'relative';
        wrapper.style.display = 'inline-block';
        wrapper.style.lineHeight = '0';
        var parent = img.parentNode;
        if (!parent) { return null; }
        parent.insertBefore(wrapper, img);
        wrapper.appendChild(img);
        img.__imgTranslateWrapped = true;
        return wrapper;
      }

      function report(img) {
        var src = currentSrc(img);
        if (!src || src.indexOf('data:') === 0) { return; }
        if (!img.__imgTranslateId) {
          img.__imgTranslateId = 'imgtranslate-' + (counter++);
          img.setAttribute('data-imgtranslate-id', img.__imgTranslateId);
        }
        ensureWrapped(img);
        if (window.webkit && window.webkit.messageHandlers.imgTranslateBridge) {
          window.webkit.messageHandlers.imgTranslateBridge.postMessage({
            id: img.__imgTranslateId,
            src: src
          });
        }
      }

      var intersectionObserver = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) { return; }
          var img = entry.target;
          if (isCandidate(img)) { report(img); }
        });
      }, { root: null, rootMargin: '0px 0px 200% 0px', threshold: 0.01 });

      function watch(img) {
        if (watched.has(img)) { return; }
        watched.add(img);
        intersectionObserver.observe(img);

        var attrObserver = new MutationObserver(function () {
          if (isCandidate(img)) { report(img); }
        });
        attrObserver.observe(img, {
          attributes: true,
          attributeFilter: ['src', 'data-src', 'srcset']
        });
      }

      function scan(root) {
        if (!root.querySelectorAll) { return; }
        var imgs = root.querySelectorAll('img');
        for (var i = 0; i < imgs.length; i++) { watch(imgs[i]); }
      }

      scan(document);

      var domObserver = new MutationObserver(function (mutations) {
        mutations.forEach(function (mutation) {
          mutation.addedNodes.forEach(function (node) {
            if (node.nodeType !== 1) { return; }
            if (node.tagName === 'IMG') { watch(node); }
            scan(node);
          });
        });
      });
      domObserver.observe(document.documentElement, { childList: true, subtree: true });

      // ⚠️ 2026-09-03:Cyril 拍板「品質優先」——與其邊捲邊翻(永遠追不上
      // VLM 的處理速度,體驗很差),改成原生端呼叫這個函式,無視目前捲動
      // 位置,把頁面上「現在就找得到」的候選圖片**全部**立刻回報,原生端
      // 收到後在畫面上蓋一層進度遮罩,全部翻完才讓使用者開始捲動閱讀。
      // 回傳值是這次回報的張數,原生端用來知道「翻完幾張才算全部完成」。
      //
      // 只處理「現在 DOM 裡已經存在」的圖——如果站方是虛擬捲動(圖片節點
      // 要捲到夠近才會被插入 DOM),這個函式在使用者開始捲動前也看不到
      // 那些還沒被插入的圖,那種情況下「整話一次翻完」這個模式本身就不
      // 適用那種站,需要另外討論。
      window.imgTranslateReportAll = function () {
        scan(document);
        var imgs = document.querySelectorAll('img');
        var count = 0;
        for (var i = 0; i < imgs.length; i++) {
          if (isCandidate(imgs[i])) {
            report(imgs[i]);
            count++;
          }
        }
        return count;
      };

      // 原生端翻譯完成後呼叫這個函式回填。座標是相對圖片本身的百分比
      // (跟 Vision 的 0-1 正規化座標系一致),wrapper 的大小就等於 img 的
      // 渲染尺寸(inline-block 貼合內容),所以直接用百分比定位、不用原生端
      // 算螢幕座標——瀏覽器自己處理縮放/捲動。
      window.imgTranslateApplyOverlay = function (elementId, blocks) {
        var img = document.querySelector('img[data-imgtranslate-id="' + elementId + '"]');
        if (!img) { return; }
        var wrapper = img.parentElement;
        if (!wrapper || !wrapper.hasAttribute('data-imgtranslate-wrapper')) { return; }

        var old = wrapper.querySelectorAll('.imgtranslate-block');
        for (var i = 0; i < old.length; i++) { old[i].remove(); }

        blocks.forEach(function (block) {
          var div = document.createElement('div');
          div.className = 'imgtranslate-block';
          div.style.position = 'absolute';
          div.style.left = block.left + '%';
          div.style.top = block.top + '%';
          div.style.width = block.width + '%';
          div.style.height = block.height + '%';
          div.style.background = 'rgba(255,255,255,0.92)';
          div.style.color = '#111';
          div.style.display = 'flex';
          div.style.alignItems = 'center';
          div.style.justifyContent = 'center';
          div.style.textAlign = 'center';
          div.style.overflow = 'hidden';
          div.style.fontWeight = '700';
          div.style.lineHeight = '1.15';
          div.style.boxSizing = 'border-box';
          div.style.padding = '2%';
          div.style.pointerEvents = 'none';
          // ⚠️ 2026-09-04:原本字級只看框的高度,完全沒看框的寬度、也沒看
          // 譯文實際字數。框的大小是照**原文**(來源語言)的 bounding box
          // 撐出來的——如果翻譯後的中文字數比原文多、需要換行的行數比框高
          // 能容納的行數多,超出的部分會被下面的 `overflow: hidden` 直接
          // 裁掉(裝機實測抓到這個現象)。改成「框面積 ÷ 字數」估一個字級,
          // 跟原本「框高 × 0.4」的上限取較小值——譯文字數越多,估出來的
          // 字級越小,降低裁切風險。`2.2` 是「每個字大概要佔多少字級平方的
          // 面積(含行距/字距開銷)」的起手估計值,沒有裝機驗證過精確度,
          // 需要下一輪測試校正。
          var boxWidthPx = wrapper.clientWidth * (block.width / 100);
          var boxHeightPx = wrapper.clientHeight * (block.height / 100);
          var charCount = Math.max(block.text.length, 1);
          var areaBasedSize = Math.sqrt((boxWidthPx * boxHeightPx) / (charCount * 2.2));
          var fontSize = Math.max(10, Math.min(areaBasedSize, boxHeightPx * 0.4, 28));
          div.style.fontSize = fontSize + 'px';
          div.textContent = block.text;
          wrapper.appendChild(div);
        });
      };
    })();
    """#
}

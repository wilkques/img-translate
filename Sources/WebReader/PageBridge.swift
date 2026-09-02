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

      function isCandidate(img) {
        var rect = img.getBoundingClientRect();
        return rect.width >= 200 && rect.height >= 200;
      }

      function currentSrc(img) {
        return img.currentSrc || img.src || img.getAttribute('data-src') || '';
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
          // 字級用區塊實際渲染高度換算,不是靠 CSS 單位——wrapper 的
          // clientHeight 就是 img 目前的螢幕渲染高度。
          var boxHeightPx = wrapper.clientHeight * (block.height / 100);
          var fontSize = Math.max(10, Math.min(boxHeightPx * 0.35, 28));
          div.style.fontSize = fontSize + 'px';
          div.textContent = block.text;
          wrapper.appendChild(div);
        });
      };
    })();
    """#
}

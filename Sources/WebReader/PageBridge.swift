import Foundation

/// 注入進網頁的偵測腳本(第一輪只做「找圖+回報網址」,還不含疊字——
/// 疊字要等風險驗證過(cookie/referer 抓不抓得到圖、lazy-load 網址等不等得到)
/// 才值得投入,見 `notes/` 對應那輪的規劃)。
///
/// 設計重點:
/// - 用 `IntersectionObserver` + 放大的 `rootMargin`(往下多抓 2 個螢幕高度)
///   提前偵測即將捲入視窗的圖片,而不是等圖片真的可見才回報——這是「看起來
///   即時」的關鍵,原生端才有時間先把翻譯準備好。
/// - 漫畫站幾乎都用 lazy-load(先塞 `data-src`,捲到才由網站自己的 JS 換成
///   `src`),`IntersectionObserver` 進入視窗那一刻不保證 `src`已經換好,所以
///   額外用 `MutationObserver` 盯每個 `<img>` 的屬性變化,src 換好才真的回報。
/// - 用 `MutationObserver` 盯整個文件的節點新增,涵蓋無限捲動網站動態插入
///   新 `<img>` 的情況(不是只在頁面剛載入時掃一次)。
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

      function report(img) {
        var src = currentSrc(img);
        if (!src || src.indexOf('data:') === 0) { return; }
        if (!img.__imgTranslateId) {
          img.__imgTranslateId = 'imgtranslate-' + (counter++);
        }
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
    })();
    """#
}

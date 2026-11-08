"""把 Toast UI 的 css/js 内联进单个 HTML。

为什么必须内联：WKWebView 从 file:// 加载 HTML 时，同目录的 <script src> 可能被
静默拒绝——页面能加载完成，但脚本一行都不执行，`toastui` 未定义，
而且没有任何错误回调。真机上连试三版都卡在这里。

内联之后没有子资源请求，也就不存在"某个 js 没加载上"这类失败。
产物约 1.1MB，作为单个资源文件随包分发。
"""
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
editor = root / "Sources/ClipNote2/Resources/editor"
src = root / "editor-src"

# 用 esbuild 自打的包，不是 npm 里的 dist。
# 原因：dist/toastui-editor.js 把 prosemirror-* 当外部依赖，内联后运行时会抛
# "Cannot read properties of undefined (reading 'PluginKey')"，
# 结果 toastui 存在、Editor 不存在——三次白跑的真正原因。
# 重打：cd editor-src && npx esbuild entry.js --bundle --format=iife --minify --outfile=editor-all.js
css = (src / "editor-all.css").read_text(encoding="utf-8")
dark = (editor / "toastui-editor-dark.css").read_text(encoding="utf-8")
js = (src / "editor-all.js").read_text(encoding="utf-8")
i18n = (editor / "zh-cn.js").read_text(encoding="utf-8")

# 内联到 <script> 里时，字符串中出现的 </script 会提前闭合标签
js = js.replace("</script", "<\\/script")
i18n = i18n.replace("</script", "<\\/script")

head = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
""" + css + "\n" + dark + """
html, body { margin:0; padding:0; height:100%; background:#fff; }
body { position: relative; }
#editor { height:100%; }
.toastui-editor-defaultUI { border:none; }

/* 占位符默认是绝对定位 + 不换行的 ::before，长句在 390pt 上会被右边缘硬切，
   看起来就像排版坏了。给它左右边界，让它正常折行。 */
.toastui-editor-contents-placeholder:before,
.ProseMirror-placeholder:before {
  position: absolute;
  left: 20px;
  right: 20px;
  white-space: normal;
  word-break: break-word;
  color: #9aa1ad;
}

/* ── 单栏：把宽度还给正文 ───────────────────────────────────────
   默认左右各 25px，在 390pt 的屏上等于吃掉 50pt。改成 20，和 App 的
   Metric.pagePad 对齐，正文与页面其它部分落在同一条视觉边线上。
   底部留 44px：不留的话键盘弹起时最后一行正好压在键盘边上。 */
.toastui-editor-defaultUI .toastui-editor-contents {
  padding: 14px 20px 44px;
}
.toastui-editor-defaultUI .ProseMirror {
  padding: 14px 20px 44px;
}

/* ── 工具栏：一行到底，横向滑动 ─────────────────────────────────
   默认既不换行也不滚动：32px 的按钮被 flex 压到 20 出头，
   结果「看得见、点不准」。子项必须不许收缩，容器自己滚。 */
.toastui-editor-defaultUI-toolbar {
  flex-wrap: nowrap;
  overflow-x: auto;
  overflow-y: hidden;
  -webkit-overflow-scrolling: touch;
  overscroll-behavior-x: contain;
  padding: 0 6px;
  scrollbar-width: none;
}
.toastui-editor-defaultUI-toolbar::-webkit-scrollbar { display: none; }
.toastui-editor-defaultUI-toolbar > * { flex: 0 0 auto; }
.toastui-editor-defaultUI-toolbar button { flex: 0 0 auto; }
.toastui-editor-toolbar-divider { margin: 14px 8px; }

/* ── 右缘渐隐 ───────────────────────────────────────────────────
   横向滑动真正的问题不是不能滑，是「不知道还能滑」。
   渐隐必须渐到工具栏自己的底色 #f7f9fc；渐到纯白会变成一条白杠，
   比没有提示更糟。滑到底时由 JS 摘掉 .on，否则会谎报「右边还有」。 */
#edge-fade {
  position: absolute;
  top: 0; right: 0;
  width: 36px; height: 45px;
  pointer-events: none;
  opacity: 0;
  transition: opacity .18s ease;
  background: linear-gradient(to right, rgba(247,249,252,0), #f7f9fc 58%);
  z-index: 10;
}
#edge-fade.on { opacity: 1; }
#edge-fade::after {
  content: "";
  position: absolute;
  top: 50%; right: 9px;
  width: 6px; height: 6px;
  margin-top: -5px;
  border-top: 1.5px solid #9aa1ad;
  border-right: 1.5px solid #9aa1ad;
  transform: rotate(45deg);
}

/* 「更多」按钮只有在我们确认「按钮全留在栏里」之后才隐藏（见脚本里的 no-collapse）。
   无条件隐藏是危险的：万一 clientWidth 改写在某些 WebKit 版本上不生效，
   Toast UI 会把按钮折叠进 ⋯，而 ⋯ 又被藏起来——那就等于把功能藏死了。 */
body.no-collapse .toastui-editor-defaultUI-toolbar .more { display: none; }
</style>
</head>
<body>
<div id="editor"></div>
<div id="edge-fade" aria-hidden="true"></div>
<script>
"""

body = """
</script>
<script>
"""

script = """
</script>
<script>
(function () {
  function post(p) {
    try { window.webkit.messageHandlers.editor.postMessage(p); } catch (e) {}
  }
  window.onerror = function (m, s, l) {
    post({ type: 'error', message: m + ' @' + (s || '') + ':' + l });
  };
  if (typeof toastui === 'undefined' || !toastui.Editor) {
    post({ type: 'error', message: 'toastui 未定义（内联脚本未执行）' });
    return;
  }
  var initial = (window.__INITIAL_MARKDOWN__ || "");
  var editor;

  // ── 关掉 Toast UI 自己的「溢出折叠」 ────────────────────────────
  // 它按工具栏 clientWidth 判定放不下时，会把整组按钮搬进 ⋯ 下拉
  // （classifyToolbarItems → dropdownItems）。手机宽 390pt、15 个按钮约 630pt，
  // 于是必然全被折叠——用户看到的是一个 ⋯，横向滑动永远不会发生。
  // 交接文档要的是「横滑 + 右缘渐隐」，所以这里让判定读到足够大的宽度：
  // 按钮全部留在工具栏里，由容器的 overflow-x 去滚。
  // 只对这一个元素生效，不影响页面其它任何元素。
  (function () {
    var desc = Object.getOwnPropertyDescriptor(Element.prototype, 'clientWidth');
    if (!desc || !desc.get) return;
    Object.defineProperty(Element.prototype, 'clientWidth', {
      configurable: true,
      get: function () {
        if (this.classList && this.classList.contains('toastui-editor-defaultUI-toolbar')) {
          return 100000;
        }
        return desc.get.call(this);
      }
    });
  })();

  try {
    editor = new toastui.Editor({
      el: document.querySelector('#editor'),
      height: '100%',
      // 单栏所见即所得。手机上宽 390pt，双栏每栏不到 190pt，
      // 预览栏里一行中文只有十来个字——那不是「对照」，是「都看不清」。
      initialEditType: 'wysiwyg',
      // 「编辑 / 预览」页签在这个形态里已经没有对偶：只有一个栏。
      hideModeSwitch: true,
      placeholder: '写点什么：这条视频对你有什么用、哪句话值得记、下次要试什么。',
      initialValue: initial,
      language: 'zh-CN',
      usageStatistics: false,
      toolbarItems: [
        ['heading','bold','italic','strike'],
        ['hr','quote'],
        ['ul','ol','task','indent','outdent'],
        ['table','link'],
        ['code','codeblock']
      ]
    });
  } catch (e) {
    post({ type: 'error', message: '初始化失败：' + (e && e.message ? e.message : e) });
    return;
  }
  // 留一个把手：jsdom 校验要拿实例做内容回环，真机排障也能直接问它状态。
  window.__editorInstance = editor;
  var timer = null;
  editor.on('change', function () {
    if (timer) clearTimeout(timer);
    timer = setTimeout(function () {
      post({ type: 'change', value: editor.getMarkdown() });
    }, 350);
  });
  window.__setMarkdown = function (md) {
    if (editor.getMarkdown() !== md) editor.setMarkdown(md || '', false);
  };

  // 右缘渐隐：只在「确实能往右滑」且「还没滑到底」时出现。
  // 两个条件都要，少一个就是骗人——没有可滑的内容却露出箭头，
  // 用户会去戳一个不存在的按钮。
  var toolbar = document.querySelector('.toastui-editor-defaultUI-toolbar');
  var fade = document.getElementById('edge-fade');

  // 确认折叠真的被绕开了（15 个按钮全在栏里）。没绕开就保留 ⋯，
  // 宁可让用户点 ⋯ 展开，也不能让「表格/代码块」无处可去。
  if (toolbar && toolbar.querySelectorAll('button:not(.more)').length > 1) {
    document.body.classList.add('no-collapse');
  } else {
    // 不报 error：这样只是退化（用 ⋯ 展开），编辑器本身还能用，
    // 报 error 会把用户直接退回纯文本，属于把小问题放大。
    post({ type: 'trace', message: '工具栏折叠未绕开，退回 ⋯ 展开' });
  }
  function syncFade() {
    if (!toolbar || !fade) return;
    // 用 getBoundingClientRect 而不是 clientWidth：后者被上面改成了哨兵值，
    // 读它会把「还能滑多远」永远算成负的，渐隐就再也不出现了。
    var visible = Math.round(toolbar.getBoundingClientRect().width);
    var rest = toolbar.scrollWidth - visible - toolbar.scrollLeft;
    fade.style.height = toolbar.offsetHeight + 'px';
    fade.classList.toggle('on', rest > 2);
  }
  if (toolbar) {
    toolbar.addEventListener('scroll', syncFade, { passive: true });
    window.addEventListener('resize', syncFade);
    window.addEventListener('orientationchange', syncFade);
    // 两拍：0ms 时字体还没量完，300ms 才是稳定宽度。
    setTimeout(syncFade, 0);
    setTimeout(syncFade, 300);
  }

  // 一句话状态，给 jsdom 校验和真机排障用。
  window.__editorProbe = function () {
    var tb = document.querySelector('.toastui-editor-defaultUI-toolbar');
    var tab = document.querySelector('.toastui-editor-md-tab-container');
    var more = tb ? tb.querySelector('button.more') : null;
    var items = tb ? tb.querySelectorAll('button:not(.more)').length : -1;
    return {
      mode: editor.mode || (editor.getCurrentMode ? editor.getCurrentMode() : '?'),
      tabVisible: !!tab && getComputedStyle(tab).display !== 'none',
      items: items,
      moreVisible: !!more && getComputedStyle(more).display !== 'none',
      toolbarWidth: tb ? Math.round(tb.getBoundingClientRect().width) : -1,
      toolbarScrollWidth: tb ? tb.scrollWidth : -1,
      fadeVisible: !!(fade && fade.classList.contains('on')),
      chars: editor.getMarkdown().length
    };
  };

  post({ type: 'ready' });
})();
</script>
</body>
</html>
"""

html = head + js + body + i18n + script

out = root / "Sources/ClipNote2/Resources/editor-bundle.html"
out.write_text(html, encoding="utf-8")
print("wrote", out, round(len(html.encode("utf-8")) / 1024), "KB")

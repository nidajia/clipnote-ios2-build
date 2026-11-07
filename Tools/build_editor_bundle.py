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
#editor { height:100%; }
.toastui-editor-defaultUI { border:none; }
</style>
</head>
<body>
<div id="editor"></div>
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
  try {
    editor = new toastui.Editor({
      el: document.querySelector('#editor'),
      height: '100%',
      initialEditType: 'markdown',
      previewStyle: 'tab',
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

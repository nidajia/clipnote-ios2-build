"""把自研编辑器的 JS/CSS 内联进单个 HTML。

为什么必须内联：WKWebView 从 file:// 加载 HTML 时，同目录的 <script src> / <link>
可能被静默拒绝——页面能加载完成，但脚本一行都不执行，而且没有任何错误回调。
真机上连试三版都卡在这里。单文件没有子资源请求，这类失败整类消失。

产物约 0.5MB，作为单个资源文件随包分发。

改了编辑器源码后必须重跑：
    cd editor-src && npx esbuild entry.js --bundle --format=iife --minify --outfile=editor-all.js
    cd .. && python Tools/build_editor_bundle.py
"""
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
src = root / "editor-src"

css = (src / "editor-all.css").read_text(encoding="utf-8")
js = (src / "editor-all.js").read_text(encoding="utf-8")

# 内联到 <script> 里时，字符串中出现的 </script 会提前闭合标签
js = js.replace("</script", "<\\/script")

html = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
""" + css + """
</style>
</head>
<body>
<div id="cn-app"></div>
<script>
""" + js + """
</script>
</body>
</html>
"""

out = root / "Sources/ClipNote2/Resources/editor-bundle.html"
out.write_text(html, encoding="utf-8")
print("wrote", out, round(len(html.encode("utf-8")) / 1024), "KB")

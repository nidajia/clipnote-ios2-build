// 打包入口。
//
// 与旧版的区别：旧版把 Toast UI 装到 window 上，再由一段内联脚本初始化；
// 现在直接挂载我们自己的编辑器。
//
// 产物仍然是**单个 HTML**（CSS/JS 全部内联）：WKWebView 从 file:// 加载
// 同目录子资源时可能静默不执行——那个坑踩过三次，单文件让这类失败整类消失。
//
// 旧的 Toast UI 实现保留在 git 历史（origin/main 的 editor-src/entry.js），
// 需要对照或回退时按提交取，不要在新代码里留双份。
import { mount } from "./src/editor.js";

function postError(message) {
  try {
    window.webkit.messageHandlers.editor.postMessage({ type: "error", message });
  } catch (e) {
    /* 本地预览没有桥，不当作错误 */
  }
}

function boot() {
  const root = document.getElementById("cn-app");
  if (!root) {
    postError("页面缺少 #cn-app 容器");
    return;
  }
  try {
    mount(root);
  } catch (error) {
    const detail = error && error.message ? error.message : String(error);
    postError(`初始化失败：${detail}`);
    throw error;
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}

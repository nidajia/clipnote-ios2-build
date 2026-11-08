// 编辑器形态自检：在 jsdom 里真的执行这份 HTML，回答五个问题——
//   1. 脚本是否完整执行（toastui.Editor 是函数）
//   2. 形态是不是单栏所见即所得（wysiwyg，且页签容器不可见）
//   3. 工具栏按钮是不是全留在栏里（没有被 Toast UI 折叠进 ⋯）
//   4. 横向滑动与右缘渐隐的样式是否在位
//   5. 内容回环是否成立（写进去的 Markdown 能不能原样拿出来）
//
// 为什么不用肉眼看截图做这件事：截图只能证明「画出来了」，
// 证明不了 mode 到底是哪一个、按钮到底折叠没折叠——而这两件事才是这一轮的全部内容。
//
// 注意：jsdom 不做布局，工具栏宽度一律是 0，所以「能不能滑」在这里只能验结构和 CSS，
// 真实宽度下的表现由真机截图负责。这条边界写在这里，免得下次又被 0 宽度骗一遍。
const { JSDOM, VirtualConsole } = require("jsdom");
const fs = require("fs");
const path = require("path");

const file = path.join(__dirname, "../Sources/ClipNote2/Resources/editor-bundle.html");
const html = fs.readFileSync(file, "utf8");

const errors = [];
const posted = [];
const vc = new VirtualConsole();
vc.on("jsdomError", (e) => errors.push("jsdomError: " + String(e.message || e).slice(0, 200)));
vc.on("error", (m) => errors.push("console.error: " + String(m).slice(0, 200)));

const dom = new JSDOM(html, {
  runScripts: "dangerously",
  pretendToBeVisual: true,
  virtualConsole: vc,
  url: "file:///tmp/editor-bundle.html",
  beforeParse(window) {
    // 桥：真机上由 WKScriptMessageHandler 提供，这里截下来当断言依据。
    window.webkit = {
      messageHandlers: {
        editor: { postMessage: (p) => posted.push(p) },
      },
    };
  },
});

const failures = [];
function ok(cond, label, detail) {
  console.log(`${cond ? "PASS" : "FAIL"}  ${label}${detail === undefined ? "" : "  →  " + detail}`);
  if (!cond) failures.push(label);
}

setTimeout(() => {
  const w = dom.window;
  const css = html.slice(0, html.indexOf("</style>"));

  console.log("── 加载 ──");
  ok(typeof w.toastui === "object" && w.toastui !== null, "toastui 已定义", typeof w.toastui);
  ok(typeof w.toastui?.Editor === "function", "toastui.Editor 是构造函数", typeof w.toastui?.Editor);
  ok(errors.length === 0, "运行期零报错", errors.slice(0, 2).join(" | ") || "0 条");
  ok(posted.some((p) => p.type === "ready"), "已向原生端发出 ready");

  console.log("── 形态 ──");
  const probe = typeof w.__editorProbe === "function" ? w.__editorProbe() : null;
  ok(probe !== null, "__editorProbe 可用");
  if (probe) {
    ok(probe.mode === "wysiwyg", "编辑模式是 wysiwyg", probe.mode);
    ok(probe.tabVisible === false, "「编辑/预览」页签不可见", probe.tabVisible ? "仍可见" : "display:none");
    ok(probe.items === 15, "15 个按钮都在工具栏里", `${probe.items} 个`);
    ok(probe.moreVisible === false, "没有多余的 ⋯ 折叠按钮", probe.moreVisible ? "仍可见" : "display:none");
    ok(w.document.body.classList.contains("no-collapse"), "已启用「不折叠」模式（失败会保留 ⋯）");
  }

  console.log("── 横滑与渐隐（结构，非布局）──");
  ok(/\.toastui-editor-defaultUI-toolbar\s*\{[^}]*overflow-x:\s*auto/.test(css), "工具栏容器可横向滚动");
  ok(/\.toastui-editor-defaultUI-toolbar\s*>\s*\*\s*\{[^}]*flex:\s*0 0 auto/.test(css), "按钮不被压缩");
  ok(/\.toastui-editor-defaultUI-toolbar::-webkit-scrollbar\s*\{\s*display:\s*none/.test(css), "滚动条已隐藏");
  ok(/body\.no-collapse \.toastui-editor-defaultUI-toolbar \.more\s*\{\s*display:\s*none/.test(css), "⋯ 折叠按钮已隐藏（有条件）");
  ok(/#edge-fade\.on\s*\{\s*opacity:\s*1/.test(css), "右缘渐隐有开启态");
  ok(!!w.document.getElementById("edge-fade"), "渐隐层已挂进 DOM");
  ok(/toastui-editor-defaultUI-toolbar'\)\) \{\s*return 100000/.test(html), "折叠判定被绕开（clientWidth 哨兵）");

  console.log("── 内容回环 ──");
  const editor = w.__editorInstance;
  if (editor) {
    editor.setMarkdown("## 标题\n\n一段正文，含 **粗体**。\n\n- 甲\n- 乙", false);
    const back = editor.getMarkdown();
    ok(back.includes("## 标题"), "二级标题原样保留", back.split("\n")[0]);
    ok(back.includes("**粗体**"), "粗体标记原样保留");
    // 列表符号可能被归一化成 *，只认内容不认符号——这不是缺陷。
    ok(back.includes("甲") && back.includes("乙"), "列表项原样保留");
  } else {
    ok(false, "能拿到编辑器实例（__editorInstance）");
  }

  setTimeout(() => {
    const changed = posted.find((p) => p.type === "change");
    ok(!!changed, "内容变化会回传 change 事件", changed ? `${String(changed.value).length} 字` : "未收到");

    console.log("");
    if (failures.length) {
      console.log(`结果：${failures.length} 项未通过 —— ${failures.join(" / ")}`);
      process.exit(1);
    }
    console.log("结果：全部通过");
    process.exit(0);
  }, 600);
}, 1800);

const { JSDOM, VirtualConsole } = require("jsdom");
const fs = require("fs");
const html = fs.readFileSync("../Sources/ClipNote2/Resources/editor-bundle.html", "utf8");

const errors = [];
const vc = new VirtualConsole();
vc.on("jsdomError", (e) => errors.push("jsdomError: " + String(e.message || e).slice(0, 200)));
vc.on("error", (m) => errors.push("console.error: " + String(m).slice(0, 200)));

const dom = new JSDOM(html, {
  runScripts: "dangerously",
  pretendToBeVisual: true,
  virtualConsole: vc,
  url: "file:///tmp/editor-bundle.html",
});

setTimeout(() => {
  const w = dom.window;
  console.log("toastui:", typeof w.toastui);
  console.log("toastui.Editor:", w.toastui && typeof w.toastui.Editor);
  console.log("页面里是否出现编辑器工具栏:",
    w.document.querySelectorAll(".toastui-editor-toolbar-group").length);
  console.log("编辑区是否存在:", w.document.querySelectorAll(".toastui-editor-main").length);
  console.log("errors:", errors.length);
  errors.slice(0, 3).forEach((e) => console.log("  -", e));
  process.exit(0);
}, 1500);

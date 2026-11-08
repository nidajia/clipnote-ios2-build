// 自研编辑器的冒烟自检：先在 jsdom 里跑，回答「有没有起来」。
// 布局类问题（能不能横滑、渐隐在不在）jsdom 一律返回 0，交给真实浏览器那张图。
const { JSDOM, VirtualConsole } = require("jsdom");
const fs = require("fs");
const path = require("path");

const file = path.join(__dirname, "../Sources/ClipNote2/Resources/editor-bundle.html");
const html = fs.readFileSync(file, "utf8");

const errors = [];
const posted = [];
const vc = new VirtualConsole();
vc.on("jsdomError", (e) => errors.push(String(e.message || e).slice(0, 300)));
vc.on("error", (m) => errors.push("console.error: " + String(m).slice(0, 300)));

const dom = new JSDOM(html, {
  runScripts: "dangerously",
  pretendToBeVisual: true,
  virtualConsole: vc,
  url: "file:///tmp/editor.html",
  beforeParse(window) {
    window.webkit = { messageHandlers: { editor: { postMessage: (p) => posted.push(p) } } };
  },
});

const failures = [];
function ok(cond, label, detail) {
  console.log(`${cond ? "PASS" : "FAIL"}  ${label}${detail === undefined ? "" : "  →  " + detail}`);
  if (!cond) failures.push(label);
}

setTimeout(() => {
  const w = dom.window;
  const d = w.document;
  const probe = typeof w.__probe === "function" ? w.__probe() : null;

  console.log("── 启动 ──");
  ok(errors.length === 0, "运行期零报错", errors.slice(0, 2).join(" | ") || "0 条");
  ok(posted.some((p) => p.type === "ready"), "已向原生端发出 ready");
  ok(probe && probe.ok, "__probe 可用");

  console.log("── 结构 ──");
  ok(!!d.querySelector(".cn-tb"), "工具栏已挂载");
  ok(!!d.querySelector(".ProseMirror"), "编辑区已挂载");
  ok((probe && probe.items) === 15, "工具栏 15 个按钮", probe ? `${probe.items} 个` : "-");
  ok(!!d.querySelector(".cn-tb-fade"), "右缘渐隐层存在");
  ok(d.querySelectorAll(".cn-tb-divider").length === 4, "4 条分隔线",
    `${d.querySelectorAll(".cn-tb-divider").length} 条`);

  console.log("── 内容 ──");
  const initial = w.__getMarkdown ? w.__getMarkdown() : null;
  ok(typeof initial === "string", "__getMarkdown 可用", initial && initial.slice(0, 30));

  const sample = "# 标题\n\n一段正文，含 **粗体**。\n\n- 甲\n- 乙\n\n> 引用\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n```js\nconst x = 1\n```";
  if (w.__replaceAll) w.__replaceAll(sample);
  const back = w.__getMarkdown ? w.__getMarkdown() : "";
  ok(back.includes("# 标题"), "一级标题往返保留");
  ok(back.includes("**粗体**"), "粗体往返保留");
  ok(back.includes("- 甲"), "无序列表往返保留");
  ok(back.includes("> 引用"), "引用往返保留");
  ok(back.includes("| a | b |"), "表格往返保留", back.split("\n").find((l) => l.startsWith("|")) || "无");
  ok(back.includes("```js"), "代码块语言保留");

  const tasks = "- [ ] 还没做\n- [x] 已经做完";
  w.__replaceAll(tasks);
  const taskBack = w.__getMarkdown();
  ok(taskBack.includes("- [ ] 还没做"), "未勾选任务往返保留", taskBack.split("\n")[0]);
  ok(taskBack.includes("- [x] 已经做完"), "已勾选任务往返保留");

  // 普通项和任务项写在同一个列表里，是笔记里最常见的形态。
  // 用逐字相等断言：这里一旦变形（比如 ul 被当成 ol），只有精确比较才抓得住。
  const mixed = "- 普通一\n- 普通二\n- [ ] 任务一\n- [x] 任务二";
  w.__replaceAll(mixed);
  const mixedBack = w.__getMarkdown();
  ok(mixedBack === mixed, "混排列表逐字往返", JSON.stringify(mixedBack));

  setTimeout(() => {
    const changed = posted.filter((p) => p.type === "change");
    ok(changed.length > 0, "内容变化回传 change", `${changed.length} 次`);
    const errs = posted.filter((p) => p.type === "error");
    ok(errs.length === 0, "没有向原生端报 error", errs.map((e) => e.message).join(" | ") || "0 条");

    console.log("");
    if (failures.length) {
      console.log(`结果：${failures.length} 项未通过 —— ${failures.join(" / ")}`);
      process.exit(1);
    }
    console.log("结果：全部通过");
    process.exit(0);
  }, 700);
}, 1500);
